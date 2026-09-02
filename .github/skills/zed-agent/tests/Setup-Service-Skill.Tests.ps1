Describe 'setup-service skill (extracted from agent.md)' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')
        $script:SkillPath = Join-Path $repoRoot '.github\skills\setup-service\SKILL.md'
        $script:AgentMdPath = Join-Path $repoRoot '.github\agents\ZedAgent.agent.md'
    }

    Context 'File presence' {
        It 'SKILL.md exists at .github/skills/setup-service/SKILL.md' {
            Test-Path $script:SkillPath | Should -BeTrue
        }
    }

    Context 'YAML frontmatter' {
        BeforeAll {
            $script:Raw = Get-Content $script:SkillPath -Raw
            $script:FmMatch = [regex]::Match($script:Raw, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n')
        }

        It 'starts with a YAML frontmatter block delimited by --- / ---' {
            $script:FmMatch.Success | Should -BeTrue
        }

        It 'declares name: setup-service' {
            $script:FmMatch.Groups[1].Value | Should -Match '(?m)^name:\s*setup-service\s*$'
        }

        It 'has a non-empty description that mentions the key trigger phrases' {
            $fm = $script:FmMatch.Groups[1].Value
            $fm | Should -Match 'description:'
            # The description must reference the literal user-facing commands
            $fm | Should -Match 'setup-service group'
            $fm | Should -Match 'validate'
            $fm | Should -Match '5b'
        }
    }

    Context 'Wizard body structure (all groups + phases)' {
        BeforeAll { $script:Body = Get-Content $script:SkillPath -Raw }

        $groups = @(
            'Group 1 — Service Identity',
            'Group 2 — Azure DevOps',
            'Group 3 — Service Tree ID',
            'Phase 4a — BVT Kusto',
            'Phase 4b — Canary Detection Kusto',
            'Group 5a — Notifications',
            'Group 5b — Notifications',
            'Group 6 — SafeFly',
            'Group 7 — Commit Excel',
            'Group 8 — SharePoint',
            'Group 9 — Operational Parameters',
            'Group 10 — Step Gates',
            'Group 11 — Pipeline Catalog'
        )
        foreach ($g in $groups) {
            It "contains heading: $g" {
                $script:Body | Should -Match ([regex]::Escape($g))
            }
        }

        It 'contains the Generation section' {
            $script:Body | Should -Match '(?m)^### Generation\s*$'
        }
        It 'contains the Validation section' {
            $script:Body | Should -Match '(?m)^### Validation — `setup-service validate`'
        }
    }

    Context 'Critical literal strings (behavior-bearing)' {
        BeforeAll { $script:Body = Get-Content $script:SkillPath -Raw }

        It 'preserves the hardcoded gwazire@microsoft.com agentFeedbackEmail rule' {
            $script:Body | Should -Match 'gwazire@microsoft\.com'
            $script:Body | Should -Match 'service\.agentFeedbackEmail'
        }

        It 'preserves the 16-step gate-defaults table including non-overridable Step 14' {
            $script:Body | Should -Match 'Step 14 crb-review:.*ALWAYS ON'
            $script:Body | Should -Match 'Step 6  bvt-check:'
            $script:Body | Should -Match 'Step 16 merge-back:'
        }

        It 'preserves the Phase 4b column contract (StampName, DeploymentUnit)' {
            $script:Body | Should -Match 'StampName, DeploymentUnit'
            $script:Body | Should -Match '\{\{SERVICE_FILTER\}\}'
            $script:Body | Should -Match '\{\{STAMP_PREFIX_FILTER\}\}'
        }

        It 'preserves the Phase 4a required-columns contract' {
            $script:Body | Should -Match 'WorkLoadType, Environment, TestCaseName, IssueCategory'
            $script:Body | Should -Match '\{\{PIPELINE_TRIGGER_TIME\}\}'
            $script:Body | Should -Match '\{\{RESPONSIBLE_TEAM\}\}'
        }
    }

    Context 'Agent.md stub no longer contains wizard prompts' {
        BeforeAll {
            $script:AgentBody = Get-Content $script:AgentMdPath -Raw
            # The agent file is a dispatcher: the command/step detail lives in
            # reference files it is instructed to read. The loadable surface is
            # agent.md PLUS those files, so content assertions run against the union
            # (and the negative assertions get stronger, since the wizard prompts
            # must not appear anywhere in the surface).
            $refDir = Join-Path (Split-Path -Parent (Split-Path -Parent $script:AgentMdPath)) 'skills\zed-agent\reference'
            $script:AgentSurface = $script:AgentBody
            if (Test-Path $refDir) {
                foreach ($rf in (Get-ChildItem $refDir -Filter '*.md')) {
                    $script:AgentSurface += "`n" + (Get-Content $rf.FullName -Raw)
                }
            }
        }

        It 'does not contain orphan Group N heading lines for the wizard' {
            # The wizard groups should ONLY live in the skill now.
            $script:AgentSurface | Should -Not -Match '(?m)^\*\*Group 1 — Service Identity\*\*'
            $script:AgentSurface | Should -Not -Match '(?m)^\*\*Group 11 — Pipeline Catalog\*\*'
            $script:AgentSurface | Should -Not -Match '(?m)^Phase 4a — BVT Kusto'
        }

        It 'still has the setup-service heading stub pointing to the skill' {
            $script:AgentSurface | Should -Match '## setup-service — One-Time Service Onboarding'
            $script:AgentSurface | Should -Match '\.github/skills/setup-service/SKILL\.md'
        }

        It 'still has surviving cross-references (Rule 11, Notification Routing, help row)' {
            $script:AgentSurface | Should -Match 'setup-service group 5b'
            $script:AgentSurface | Should -Match '\| `setup-service` \|'
        }

        It 'has a Skill Invocations section referencing /setup-service' {
            $script:AgentBody | Should -Match '(?m)^# Skill Invocations'
            $script:AgentBody | Should -Match '/setup-service'
        }

        It 'keeps the agent file small enough to load as a static system prompt' {
            # Learning e2f8c272b24c: at 173 KB the agent failed to load AT ALL
            # ("Static system messages and tool definitions exceed the model's
            # usable context budget", exit 1). 93 KB already consumed 76% of the
            # budget. Guard the regression at 100 KB.
            $bytes = (Get-Item $script:AgentMdPath).Length
            $bytes | Should -BeLessThan 102400 -Because "agent.md is $([math]::Round($bytes/1KB,1)) KB; above ~100 KB ZED stops loading entirely"
        }

        It 'points at reference files that exist and carry the extracted detail' {
            $refDir = Join-Path (Split-Path -Parent (Split-Path -Parent $script:AgentMdPath)) 'skills\zed-agent\reference'
            foreach ($name in @('command-behaviors.md','step-behaviors.md')) {
                $script:AgentBody | Should -Match ([regex]::Escape("reference/$name"))
                (Test-Path (Join-Path $refDir $name)) | Should -BeTrue -Because "agent.md instructs the model to read reference/$name"
            }
            # All 16 release steps must survive the extraction.
            $steps = Get-Content (Join-Path $refDir 'step-behaviors.md') -Raw
            for ($i = 1; $i -le 16; $i++) {
                $steps | Should -Match "(?m)^## Step $i[:\s]"
            }
        }
    }
}
