#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'resolve-image-tags.ps1' {
    BeforeAll {
        $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/resolve-image-tags.ps1')).Path
    }

    Context 'Push event' {
        It 'Computes correct tags for push to main' {
            $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) "gh-output-$(New-Guid).txt"
            try {
                pwsh -NoProfile -NoLogo -Command "
                    `$env:GITHUB_OUTPUT = '$outputFile'
                    `$env:EVENT_NAME = 'push'
                    `$env:REF_NAME = 'main'
                    `$env:RUN_NUMBER = '2'
                    `$env:VERSION_PREFIX = '0.1'
                    & '$($script:scriptPath)'
                " 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0

                $content = Get-Content -Path $outputFile -Raw
                $content | Should -Match 'latest_tag=main-latest'
                $content | Should -Match 'version_image_tag=0\.1\.2'
                $content | Should -Match 'versioned_tag=main-0\.1\.2'
            }
            finally {
                Remove-Item -Path $outputFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'workflow_run event' {
        It 'Uses triggering workflow branch and run number' {
            $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) "gh-output-$(New-Guid).txt"
            try {
                pwsh -NoProfile -NoLogo -Command "
                    `$env:GITHUB_OUTPUT = '$outputFile'
                    `$env:EVENT_NAME = 'workflow_run'
                    `$env:REF_NAME = 'ignored-ref'
                    `$env:RUN_NUMBER = '99'
                    `$env:WORKFLOW_RUN_HEAD_BRANCH = 'main'
                    `$env:WORKFLOW_RUN_RUN_NUMBER = '2'
                    `$env:VERSION_PREFIX = '0.1'
                    & '$($script:scriptPath)'
                " 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0

                $content = Get-Content -Path $outputFile -Raw
                $content | Should -Match 'branch_name=main'
                $content | Should -Match 'run_number=2'
                $content | Should -Match 'latest_tag=main-latest'
                $content | Should -Match 'version_image_tag=0\.1\.2'
                $content | Should -Match 'versioned_tag=main-0\.1\.2'
            }
            finally {
                Remove-Item -Path $outputFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'workflow_dispatch event' {
        It 'Computes correct tags with multi-segment version prefix' {
            $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) "gh-output-$(New-Guid).txt"
            try {
                pwsh -NoProfile -NoLogo -Command "
                    `$env:GITHUB_OUTPUT = '$outputFile'
                    `$env:EVENT_NAME = 'workflow_dispatch'
                    `$env:REF_NAME = 'main'
                    `$env:RUN_NUMBER = '7'
                    `$env:VERSION_PREFIX = '0.1.2'
                    & '$($script:scriptPath)'
                " 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0

                $content = Get-Content -Path $outputFile -Raw
                $content | Should -Match 'version_image_tag=0\.1\.2\.7'
                $content | Should -Match 'versioned_tag=main-0\.1\.2\.7'
            }
            finally {
                Remove-Item -Path $outputFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Missing EVENT_NAME' {
        It 'Exits non-zero when EVENT_NAME is not set' {
            pwsh -NoProfile -NoLogo -Command "
                `$env:EVENT_NAME = ''
                `$env:GITHUB_OUTPUT = ''
                & '$($script:scriptPath)'
            " 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
    }

    Context 'stdout fallback' {
        It 'Writes output to stdout when GITHUB_OUTPUT is not set' {
            $output = pwsh -NoProfile -NoLogo -Command "
                `$env:GITHUB_OUTPUT = ''
                `$env:EVENT_NAME = 'push'
                `$env:REF_NAME = 'dev'
                `$env:RUN_NUMBER = '5'
                `$env:VERSION_PREFIX = '1.0'
                & '$($script:scriptPath)'
            " 2>&1
            $LASTEXITCODE | Should -Be 0

            "$output" | Should -Match 'latest_tag=dev-latest'
            "$output" | Should -Match 'version_image_tag=1\.0\.5'
            "$output" | Should -Match 'versioned_tag=dev-1\.0\.5'
        }
    }
}
