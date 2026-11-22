take editor_core

// Saving a document, shared by the terminal and window frontends.
// writeBytes publishes through an exclusive temporary and an atomic replace;
// the dirty marker is cleared only after the published bytes read back equal.
// 0 on success; 23 document above 16 MiB; 20/21 read-back mismatch; 22
// read-back failed; otherwise the writeBytes status.
expose flow saveDocument(editor: edit Editor, path: view Text) => Int {
    when length(view editor.document) > 16 * 1024 * 1024 { give 23 }
    change bytes = toBytes(view editor.document)
    hold status = writeBytes(path, bytes)
    when status != 0 { give status }
    // Do not clear the dirty marker until the published file can be read back.
    choose readText(path, 16 * 1024 * 1024) {
        Ok(reopened): {
            when reopened.byteLength != length(view editor.document) { give 20 }
            change i = 0
            during i < reopened.byteLength {
                when reopened@byteAt(i) != byteAt(view editor.document, i) { give 21 }
                i += 1
            }
        },
        Err(code): { give 22 },
    }
    editorMarkSaved(edit editor)
    give 0
}

// Results of openDocument (also kept in Editor.open_failed for the prompt).
expose fixed OPEN_OK = 0
expose fixed OPEN_UNSAVED = 1
expose fixed OPEN_BAD_PATH = 2
expose fixed OPEN_READ_FAILED = 3

// Opens the path typed in the open prompt (Ctrl+O) in place of the current
// document. Unsaved changes are never discarded: the open is refused and
// the prompt stays, so the user can save first. The typed path must be
// UTF-8 (textFromBytes) and a readable UTF-8 file below 16 MiB (readText).
// On success `current` becomes the new path; the clipboard and the typed
// path survive into the new editor.
expose flow openDocument(editor: edit Editor, current: edit Text) => Int {
    when editor.document.dirty {
        editor.open_failed = OPEN_UNSAVED
        give OPEN_UNSAVED
    }
    choose textFromBytes(editor.path_input, editor.path_len) {
        Ok(path): {
            choose readText(path, 16 * 1024 * 1024) {
                Ok(source): {
                    change next = newEditor(view source)
                    each i among 0..editor.clipboard.length { next.clipboard@push(editor.clipboard[i]) }
                    each i among 0..editor.path_len { next.path_input@push(editor.path_input[i]) }
                    next.path_len = editor.path_len
                    editor = next
                    current = path
                    give OPEN_OK
                },
                Err(code): {
                    editor.open_failed = OPEN_READ_FAILED
                    give OPEN_READ_FAILED
                },
            }
        },
        Err(code): {
            editor.open_failed = OPEN_BAD_PATH
            give OPEN_BAD_PATH
        },
    }
}
