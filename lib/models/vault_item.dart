class VaultItem {
  final String id;
  final String title;
  final String originalPath;
  final String vaultPath;
  final String ext;
  final bool isAudio;
  final int fileSize;
  final DateTime addedAt;
  final String? sourceFolder;
  final Map<String, dynamic>? downloadRecord;
  final List<String> downloadFolderIds;
  final String? folderId; // Folder inside Secret Vault

  const VaultItem({
    required this.id,
    required this.title,
    required this.originalPath,
    required this.vaultPath,
    required this.ext,
    required this.isAudio,
    required this.fileSize,
    required this.addedAt,
    this.folderId,
    this.sourceFolder,
    this.downloadRecord,
    this.downloadFolderIds = const [],
  });

  VaultItem copyWith({String? vaultPath}) => VaultItem(
    id: id,
    title: title,
    originalPath: originalPath,
    vaultPath: vaultPath ?? this.vaultPath,
    ext: ext,
    isAudio: isAudio,
    fileSize: fileSize,
    addedAt: addedAt,
    folderId: folderId,
    sourceFolder: sourceFolder,
    downloadRecord: downloadRecord,
    downloadFolderIds: downloadFolderIds,
  );

  bool get isImage {
    final e = ext.toLowerCase().replaceAll('.', '');
    return [
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'bmp',
      'heic',
      'svg',
    ].contains(e);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'originalPath': originalPath,
    'vaultPath': vaultPath,
    'ext': ext,
    'isAudio': isAudio,
    'fileSize': fileSize,
    'addedAt': addedAt.toIso8601String(),
    'folderId': folderId,
    'sourceFolder': sourceFolder,
    'downloadRecord': downloadRecord,
    'downloadFolderIds': downloadFolderIds,
  };

  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      originalPath: json['originalPath'] ?? '',
      vaultPath: json['vaultPath'] ?? '',
      ext: json['ext'] ?? '',
      isAudio: json['isAudio'] ?? false,
      fileSize: json['fileSize'] ?? 0,
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt']) ?? DateTime.now()
          : DateTime.now(),
      folderId: json['folderId'],
      sourceFolder: json['sourceFolder'] as String?,
      downloadRecord: json['downloadRecord'] as Map<String, dynamic>?,
      downloadFolderIds:
          (json['downloadFolderIds'] as List?)?.whereType<String>().toList() ??
          const [],
    );
  }
}
