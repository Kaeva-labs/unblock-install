# PSScriptAnalyzer settings for the UNBLOCK installer.
#
# We gate CI on Error + Warning severity (see .github/workflows/test.yml), but a
# handful of rules fire on patterns that are *intentional and correct* for a
# user-facing CLI installer. Excluding them here keeps the lint signal honest:
# every remaining Warning/Error is a real problem worth failing the build over.
#
# Excluded rules (with rationale):
#   PSAvoidUsingWriteHost
#     install.ps1 is a one-shot, human-facing installer streamed via
#     `iwr -useb install.kaeva.app | iex`. Colored progress/onboarding output is
#     the whole point; Write-Host is the right tool here, not Write-Output
#     (which would pollute the pipeline that `iex` consumes).
#   PSAvoidUsingEmptyCatchBlock
#     Two deliberate best-effort guards: the TLS 1.2 opt-in (older PS 5.1 hosts)
#     and the version-parse fallback. Failing those silently is the intended,
#     documented behavior -- a throw would break installs on benign hosts.
#   PSUseSingularNouns
#     Cosmetic. `Compare-Versions` reads naturally; renaming a private helper
#     to satisfy a noun-pluralization linter has no value.
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseSingularNouns'
    )
}
