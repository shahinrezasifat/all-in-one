import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/site_model.dart';
import '../services/bookmark_service.dart';
import '../theme/app_colors.dart';

class BookmarkEditorSheet extends StatefulWidget {
  const BookmarkEditorSheet({super.key, this.site});

  final SiteModel? site;

  static Future<bool?> show(BuildContext context, {SiteModel? site}) {
    return showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BookmarkEditorSheet(site: site),
    );
  }

  @override
  State<BookmarkEditorSheet> createState() => _BookmarkEditorSheetState();
}

class _BookmarkEditorSheetState extends State<BookmarkEditorSheet> {
  final _form = GlobalKey<FormState>();
  final _nameFocus = FocusNode();
  late final _link = TextEditingController(text: widget.site?.url);
  late final _name = TextEditingController(text: widget.site?.title);
  bool _saving = false;
  bool _validateWhileEditing = false;
  String? _clipboardError;
  String? _saveError;

  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    String? value;
    try {
      value = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } on PlatformException {
      // Some platforms restrict clipboard access.
    }
    if (!mounted || _saving) return;
    if (value == null || value.isEmpty) {
      setState(() => _clipboardError = 'Copy a website link first.');
      return;
    }
    _link.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    setState(() {
      _clipboardError = null;
      _validateWhileEditing = true;
    });
    _form.currentState!.validate();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _clipboardError = null;
      _saveError = null;
      _validateWhileEditing = true;
    });
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final service = BookmarkService.instance;
      final site = widget.site;
      final saved = site == null
          ? await service.addBookmark(title: _name.text, url: _link.text)
          : await service.editBookmark(
              oldSite: site,
              newTitle: _name.text,
              newUrl: _link.text,
            );
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop(true);
        return;
      }
    } on Exception {
      if (!mounted) return;
    }
    setState(() {
      _saving = false;
      _saveError = 'Could not save the bookmark. Try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? AppColors.primaryLight : AppColors.primary;
    final editing = widget.site != null;
    final uri = BookmarkService.parseBookmarkUrl(_link.text);
    final suggested = uri == null ? null : BookmarkService.suggestedName(uri);
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: palette.outlineVariant),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              editing
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_add_rounded,
                              color: accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            editing ? 'Edit bookmark' : 'Add bookmark',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: _saving
                              ? null
                              : () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _link,
                      enabled: !_saving,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      autovalidateMode: _validateWhileEditing
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      validator: (value) =>
                          BookmarkService.parseBookmarkUrl(value ?? '') == null
                          ? 'Enter a valid website link.'
                          : null,
                      onChanged: (_) => setState(() => _clipboardError = null),
                      onFieldSubmitted: (_) => _nameFocus.requestFocus(),
                      decoration: InputDecoration(
                        labelText: 'Website link',
                        hintText: 'example.com',
                        prefixIcon: const Icon(Icons.link_rounded),
                        suffixIcon: TextButton(
                          onPressed: _saving ? null : _paste,
                          style: TextButton.styleFrom(foregroundColor: accent),
                          child: const Text('Paste'),
                        ),
                        errorText: _clipboardError,
                        border: outline,
                        enabledBorder: outline,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _name,
                      focusNode: _nameFocus,
                      enabled: !_saving,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.words,
                      onFieldSubmitted: (_) => _save(),
                      decoration: InputDecoration(
                        labelText: 'Bookmark name',
                        hintText: 'Optional',
                        helperText: !editing && suggested != null
                            ? 'Suggested name $suggested'
                            : null,
                        prefixIcon: const Icon(Icons.edit_outlined),
                        border: outline,
                        enabledBorder: outline,
                      ),
                    ),
                    if (_saveError != null) ...[
                      const SizedBox(height: 12),
                      Text(_saveError!, style: TextStyle(color: palette.error)),
                    ],
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 50),
                      ),
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bookmark_added_outlined, size: 20),
                      label: Text(editing ? 'Save changes' : 'Save bookmark'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
