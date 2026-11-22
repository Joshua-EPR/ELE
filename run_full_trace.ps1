# Trace the full compilation process for compiler-l
$CompilerPath = "../target/debug/l.exe"
$Tracer = "./scripts/trace_compiler.ps1"

# Lexer
& $Tracer -CompilerPath $CompilerPath -Action build -InputFile "./compiler-l/src/main.l" -Args @("--backend", "cranelift")

# Parser
# ... etc
