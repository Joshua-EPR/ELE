# ELE Language Support for Visual Studio Code

Official Visual Studio Code extension providing first-class developer tooling for the **ELE** programming language (ELE v2 syntax).

## Features

- **Full Syntax Highlighting (ELE v2 Grammar)**:
  - Canonical declaration keywords: `flow`, `shape`, `choice`, `extend`, `contract`, `fixed`, `take`, `space`, `zone`, `expose`.
  - Canonical control flow keywords: `when`, `otherwise`, `during`, `repeat`, `leave`, `proceed`, `each`, `among`, `give`, `choose`.
  - Ownership & Borrowing modifiers: `hold`, `change`, `exclusive`, `direct`, `view`, `edit`.
  - Asynchronous keywords: `later`, `wait`, `launch`.
  - Implicit receiver: `this` (and `self` legacy alias).
  - Explicit Generics: `of[T]`, e.g., `shape Box of[T]`, `flow id of[T](x: T) => T`, `List of[Int]`.
  - Canonical Method Invocations: `target@method(arg)` and `Type@direct_method()`.
  - String Interpolation: `"{variable}"` expressions with full recursive highlighting.
  - Line (`//`) and block (`/* ... */`) comments.
  - Transitional support for legacy alias tokens (`fn`, `let`, `var`, `struct`, etc.).

- **ELE v2 Code Snippets**:
  - `flow`: Function declaration
  - `shape`: Nominal data shape (struct)
  - `choice`: Algebraic enum
  - `extend`: Method implementations (`extend Type` and `extend Contract on Type`)
  - `contract`: Interface / trait declaration
  - `hold`: Immutable variable declaration
  - `change`: Mutable variable declaration
  - `fixed`: Constant definition
  - `give`: Explicit return
  - `when` / `otherwise`: Conditional branching
  - `during`: Conditional loop (`while`)
  - `each`: Collection iteration loop (`each ... among`)
  - `take`: Module import
  - `expose`: Public visibility modifier
  - `choose`: Exhaustive pattern matching (`choose expr { Pattern: { ... } }`)
  - `repeat`: Unconditional loop
  - `exclusive flow`, `direct flow`, `later flow`

- **Language Configuration**:
  - Brackets and delimiter auto-closing (`{}`, `[]`, `()`, `""`, `/**/`).
  - Indentation rules for braces and control blocks.
  - Code folding regions (`//#region` / `//#endregion`).

- **Compiler Diagnostic Integration (Problem Matcher `$ele`)**:
  - Automatically parses diagnostic output from the ELE driver (`ele build <file.l>`):
    `{filepath}:{line}:{column}: error[{code}]: {message}`
    and parser diagnostics:
    `{filepath}:{line}:{column}: error[PARSER]: {message}`
  - Enables one-click navigation directly from the VS Code Problems panel to source code locations.

---

## Configuring Tasks with the `$ele` Problem Matcher

To build ELE source files and have compiler errors display interactively in your VS Code Problems tab, add the following task to `.vscode/tasks.json` in your workspace:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "type": "shell",
      "label": "ele: build current file",
      "command": "ele",
      "args": ["build", "${file}"],
      "problemMatcher": ["$ele"],
      "group": {
        "kind": "build",
        "isDefault": true
      },
      "presentation": {
        "reveal": "always",
        "panel": "shared"
      }
    }
  ]
}
```

Whenever `ele build` emits an error such as:
```text
src/main.l:14:5: error[L0005]: uso de valor movido
src/main.l:22:1: error[PARSER]: se esperaba expresión
```
VS Code will populate the Problems panel, underline the offending token in the editor, and jump to the exact line and column upon clicking.

---

## Local Installation

### Method 1: Extension Folder Link (Development Mode)
Copy or symlink the `editors/vscode` directory into your VS Code extensions folder:
- **Windows**: `%USERPROFILE%\.vscode\extensions\ele-vscode`
- **Linux / macOS**: `~/.vscode/extensions/ele-vscode`

### Method 2: Package to VSIX
Using `@vscode/vsce`:
```bash
cd editors/vscode
npx @vscode/vsce package
code --install-extension ele-vscode-0.1.0.vsix
```

---

## ELE v2 Code Sample

```ele
take system.io

expose shape Point of[T] {
    x: T,
    y: T,
}

extend of[T] Point of[T] {
    direct flow new(x: T, y: T) => Point of[T] {
        give Point(x: x, y: y)
    }

    exclusive flow shift(dx: T, dy: T) {
        this.x += dx
        this.y += dy
    }
}

flow main() => Int {
    change pt = Point@new(10, 20)
    pt@shift(5, -2)
    hold msg = "Point: ({pt.x}, {pt.y})"
    give 0
}
```

---

## License

Apache-2.0 or MIT. See main repository LICENSE for details.
