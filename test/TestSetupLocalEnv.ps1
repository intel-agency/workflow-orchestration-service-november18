#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'setup-local-env.ps1' {
    BeforeAll {
        $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/setup-local-env.ps1')).Path
    }

    Context 'File creation' {
        BeforeAll {
            # Build a fake repo root with a scripts/ subdirectory so the script
            # resolves paths correctly ($PSScriptRoot → scripts/, parent → repo root).
            $script:fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "setup-env-test-$(New-Guid)"
            $script:fakeScripts = Join-Path $script:fakeRoot 'scripts'
            New-Item -ItemType Directory -Path $script:fakeScripts -Force | Out-Null

            # Copy the real script into the fake scripts/ directory
            Copy-Item -Path $script:scriptPath -Destination $script:fakeScripts
            $script:fakeScript = Join-Path $script:fakeScripts 'setup-local-env.ps1'

            # Create a .env.example in the fake repo root
            @(
                '# Example env file'
                'GH_ORCHESTRATION_AGENT_TOKEN=test-token-123'
                'ZHIPU_API_KEY=zhipu-key-456'
                'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY=kimi-key-789'
            ) | Set-Content -Path (Join-Path $script:fakeRoot '.env.example')
        }

        AfterAll {
            Remove-Item -Recurse -Force $script:fakeRoot -ErrorAction SilentlyContinue
        }

        It 'Creates .env from .env.example when .env does not exist' {
            $envFile = Join-Path $script:fakeRoot '.env'
            # Ensure .env does not exist
            Remove-Item -Path $envFile -ErrorAction SilentlyContinue

            pwsh -NoProfile -NoLogo -Command "& '$($script:fakeScript)'" 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $envFile | Should -Exist
        }

        It 'Does not overwrite existing .env' {
            $envFile = Join-Path $script:fakeRoot '.env'
            $sentinel = 'SENTINEL_VALUE=do-not-overwrite'
            Set-Content -Path $envFile -Value $sentinel

            pwsh -NoProfile -NoLogo -Command "& '$($script:fakeScript)'" 2>&1 | Out-Null

            $content = Get-Content -Path $envFile -Raw
            $content | Should -Match 'SENTINEL_VALUE=do-not-overwrite'
        }
    }

    Context 'CheckOnly mode' {
        BeforeAll {
            $script:fakeRoot2 = Join-Path ([System.IO.Path]::GetTempPath()) "setup-env-check-$(New-Guid)"
            $script:fakeScripts2 = Join-Path $script:fakeRoot2 'scripts'
            New-Item -ItemType Directory -Path $script:fakeScripts2 -Force | Out-Null

            Copy-Item -Path $script:scriptPath -Destination $script:fakeScripts2
            $script:fakeScript2 = Join-Path $script:fakeScripts2 'setup-local-env.ps1'
        }

        AfterAll {
            Remove-Item -Recurse -Force $script:fakeRoot2 -ErrorAction SilentlyContinue
        }

        It 'Exits non-zero when required env vars are missing' {
            # Create a .env with empty required vars so the script sources it
            $envFile = Join-Path $script:fakeRoot2 '.env'
            @(
                'GH_ORCHESTRATION_AGENT_TOKEN='
                'ZHIPU_API_KEY='
                'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY='
            ) | Set-Content -Path $envFile

            pwsh -NoProfile -NoLogo -Command "
                `$env:GH_ORCHESTRATION_AGENT_TOKEN = ''
                `$env:ZHIPU_API_KEY = ''
                `$env:KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY = ''
                & '$($script:fakeScript2)' -CheckOnly
            " 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }

        It 'Exits 0 when all required env vars are set' {
            # Create a .env with all required vars populated
            $envFile = Join-Path $script:fakeRoot2 '.env'
            @(
                'GH_ORCHESTRATION_AGENT_TOKEN=tok-abc'
                'ZHIPU_API_KEY=zhipu-abc'
                'KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY=kimi-abc'
            ) | Set-Content -Path $envFile

            pwsh -NoProfile -NoLogo -Command "
                `$env:GH_ORCHESTRATION_AGENT_TOKEN = 'tok-abc'
                `$env:ZHIPU_API_KEY = 'zhipu-abc'
                `$env:KIMI_CODE_ORCHESTRATOR_AGENT_API_KEY = 'kimi-abc'
                & '$($script:fakeScript2)' -CheckOnly
            " 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }
}
