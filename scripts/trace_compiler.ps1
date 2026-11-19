param(
    [string] $CompilerPath,
    [string] $Action,
    [string] $InputFile,
    [string[]] $Args
)

$logFile = "compiler_trace.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$command = "$CompilerPath $Action $InputFile $($Args -join ' ')"

"[$timestamp] Executing: $command" | Out-File -FilePath $logFile -Append

$startTime = Get-Date
$process = Start-Process -FilePath $CompilerPath -ArgumentList (@($Action, $InputFile) + $Args) -Wait -PassThru -RedirectStandardOutput "compiler_output.txt" -RedirectStandardError "compiler_error.txt"
$endTime = Get-Date

"[$timestamp] Finished (Exit Code: $($process.ExitCode), Duration: $(($endTime - $startTime).TotalSeconds)s)" | Out-File -FilePath $logFile -Append
