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
