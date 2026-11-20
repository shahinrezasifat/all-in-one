// Regression guard: a folder tile must NEVER count a file that is gone.
// Bug: deleting a video from inside a folder left the stale task id in
// VirtualFolder.taskIds, so the outside grid still showed "N Files" while
// opening the folder listed nothing (the detail view filters the live task
// history, the grid counted the raw id list).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snaptube_pure/models/download_task.dart';
import 'package:snaptube_pure/services/download_manager.dart';
import 'package:snaptube_pure/services/virtual_folder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DownloadTask makeTask(String id, {String? savePath}) => DownloadTask(
        id: id,
        title: 'Video $id',
        author: 'Tester',
        thumbnailUrl: '',
        formatLabel: '720p',
        ext: 'mp4',
        isAudio: false,
        originalUrl: 'https://example.test/$id',
        status: DownloadStatus.completed,
        savePath: savePath,
      );

  test('deleting a file inside a folder shrinks the folder count immediately',
      () async {
    final tmp = Directory.systemTemp.createTempSync('vf_delete');
    final filePath = '${tmp.path}/gone.mp4';
    File(filePath).writeAsBytesSync(List.filled(1024, 0));

    SharedPreferences.setMockInitialValues({
      'snaptube_virtual_folders_v2': jsonEncode([
        {
          'id': 'vf_1',
          'name': 'My Reels',
          'taskIds': ['t_alive', 't_delete', 't_ghost'],
        }
      ]),
      'saved_download_tasks': jsonEncode([
        makeTask('t_alive').toJson(),
        makeTask('t_delete', savePath: filePath).toJson(),
      ]),
    });

    final folders = VirtualFolderService.instance;
    // Startup housekeeping must drop the ghost id 't_ghost' (no such task).
    await DownloadManager.instance.ready;
    await folders.ready;
    await folders.syncWithStoredTasks();
    expect(folders.folders.single.taskIds, containsAll(['t_alive', 't_delete']));
    expect(folders.folders.single.taskIds, isNot(contains('t_ghost')));

    // Deleting the real file through the manager must strip the id from the
    // folder too — the tile count and the folder contents can never diverge.
    final manager = DownloadManager.instance;
    final target =
        manager.completedTasks.firstWhere((t) => t.id == 't_delete');
    manager.deleteTask(target);
    await Future.delayed(const Duration(milliseconds: 50));

    expect(File(filePath).existsSync(), isFalse);
    expect(folders.isTaskInFolder('vf_1', 't_delete'), isFalse);
    expect(folders.folders.single.taskIds, ['t_alive']);

    // The file no longer exists anywhere: same view inside and outside.
    final inside = manager.completedTasks
        .where((t) => folders.isTaskInFolder('vf_1', t.id))
        .toList();
    expect(inside.length, folders.folders.single.taskIds.length);

    tmp.deleteSync(recursive: true);
  });

  test('vault move strips the id from EVERY folder that held it', () async {
    // NOTE: DownloadManager/... are process-wide singletons whose _ready ran
    // with the FIRST test's mock prefs, so this pass exercises the folder
    // service itself — removeTaskOnly() calls exactly this hook.
    final folders = VirtualFolderService.instance;
    await folders.ready;
    await folders.addItemToFolderByName('My Reels', 't_vault');
    expect(folders.isTaskInFolder('vf_1', 't_vault'), isTrue);

    await folders.removeTaskEverywhere('t_vault');
    expect(folders.getFoldersContainingTask('t_vault'), isEmpty);
    expect(folders.folders.single.taskIds, ['t_alive']);

    // Unknown ids are a no-op — nothing is ever wiped by accident.
    await folders.removeTaskEverywhere('t_never_existed');
    expect(folders.folders.single.taskIds, ['t_alive']);
  });
}
