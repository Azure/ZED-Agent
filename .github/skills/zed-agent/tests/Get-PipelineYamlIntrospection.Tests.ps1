BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\scripts\Get-PipelineYamlIntrospection.ps1'

    # Fixture A — DataMover-style: stage-hardcoded cloud, flat stamp params,
    # Ev2RARollout task with ApprovalService, SDS reference via -SdsFiles.
    $script:dmYaml = @'
name: DataMover.ServiceUpgrade.PROD

trigger: none

resources:
  repositories:
    - repository: OneBranchTemplates
      type: git
      name: OneBranch.Pipelines/GovernedTemplates
      ref: refs/heads/main
    - repository: dep_specs
      type: git
      name: One/Mgmt-RecoverySvcs-DataMover
      ref: refs/heads/develop

parameters:
  - name: stamps
    type: string
    default: 'eus-01,we-01,wus2-01'
  - name: Excludestamps
    type: string
    default: ''
  - name: Regions
    type: string
    default: 'eastus,westeurope,westus2'
  - name: ExcludeRegions
    type: string
    default: ''

stages:
  - stage: Rollout
    variables:
      - name: cloud
        value: Public
      - name: DatacenterType
        value: ACTIVE
    jobs:
      - job: Prep
        steps:
          - powershell: |
              $hsp_source = "$(Pipeline.Workspace)/s/dep_specs/src/ServiceFabric/Deployment"
              New-RegionAgnosticArtifacts -SdsFiles ServiceDatacenterSettingsConfig.json -Source $hsp_source
            displayName: Generate RA artifacts
          - task: vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@2
            inputs:
              EndpointProviderType: ApprovalService
              ApprovalServiceEnvironment: Production
              StageMapName: Microsoft.Azure.Backup.Standard.ACTIVE
              ServiceRootPath: $(Pipeline.Workspace)/drop/EV2_RASpecs/$(cloud)
              RolloutSpecPath: RolloutSpec.json
              Select: Rollout
'@

    # Fixture B — Prot-style: per-cloud Script flags + per-cloud stamp params.
    $script:protYaml = @'
name: Prot.ServiceUpgrade

resources:
  repositories:
    - repository: dep_specs
      type: git
      name: One/Mgmt-RecoverySvcs-Prot
      ref: refs/heads/main

parameters:
  - name: PublicScript
    type: boolean
    default: true
  - name: FairfaxScript
    type: boolean
    default: false
  - name: MooncakeScript
    type: boolean
    default: false
  - name: Publicstamps
    type: string
    default: 'eus-01,we-01'
  - name: PublicExcludeStamps
    type: string
    default: ''
  - name: PublicRegions
    type: string
    default: 'eastus,westeurope'
  - name: PublicExcludeRegions
    type: string
    default: ''
  - name: Fairfaxstamps
    type: string
    default: 'usgv-01'
  - name: FairfaxRegions
    type: string
    default: 'usgovvirginia'

stages:
  - ${{ if eq(parameters.PublicScript, true) }}:
      - stage: PublicRollout
        jobs:
          - job: x
            steps:
              - powershell: |
                  New-RegionAgnosticArtifacts -SdsFiles ServiceDatacenterSettingsConfigActPass.json
                displayName: gen
              - task: vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@2
                inputs:
                  EndpointProviderType: ApprovalService
                  ApprovalServiceEnvironment: Production
                  StageMapName: Microsoft.Azure.Backup.Standard.ACTIVE
                  ServiceRootPath: $(Pipeline.Workspace)/drop/EV2_RASpecs/Public
                  RolloutSpecPath: RolloutSpec.json
'@

    # Pre-run both fixtures once for the per-Context assertions.
    $script:dmResult   = & $script:scriptPath -Content $script:dmYaml
    $script:protResult = & $script:scriptPath -Content $script:protYaml
}

Describe 'Get-PipelineYamlIntrospection' {

    Context 'DataMover-style (stageHardcoded, flat params)' {
        It 'detects the single hardcoded cloud' {
            $script:dmResult.cloudConvention | Should -Be 'stageHardcoded'
            $script:dmResult.cloudsDetected  | Should -Be @('Public')
            $script:dmResult.stampParamShape | Should -Be 'flat'
        }
        It 'extracts flat stamp + region defaults with YAML quoting removed' {
            $script:dmResult.flatDefaults.stamps  | Should -Be 'eus-01,we-01,wus2-01'
            $script:dmResult.flatDefaults.regions | Should -Be 'eastus,westeurope,westus2'
        }
        It 'extracts the DatacenterType variable' {
            $script:dmResult.datacenterType | Should -Be 'ACTIVE'
        }
        It 'extracts the Ev2RARollout task block' {
            $script:dmResult.ev2.taskVersion                | Should -Be 2
            $script:dmResult.ev2.endpointProviderType       | Should -Be 'ApprovalService'
            $script:dmResult.ev2.approvalServiceEnvironment | Should -Be 'Production'
            $script:dmResult.ev2.stageMapName               | Should -Be 'Microsoft.Azure.Backup.Standard.ACTIVE'
            $script:dmResult.ev2.rolloutSpecPath            | Should -Be 'RolloutSpec.json'
            $script:dmResult.ev2.datacenterType             | Should -Be 'ACTIVE'
        }
        It 'extracts SDS file name and repo source path' {
            $script:dmResult.sdsHint.fileName | Should -Be 'ServiceDatacenterSettingsConfig.json'
            $script:dmResult.sdsHint.repoPath | Should -Be 'src/ServiceFabric/Deployment'
        }
        It 'resolves the self-repo and base branch' {
            $script:dmResult.selfRepo.name       | Should -Be 'Mgmt-RecoverySvcs-DataMover'
            $script:dmResult.selfRepo.baseBranch | Should -Be 'develop'
            $script:dmResult.selfRepo.alias      | Should -Be 'dep_specs'
        }
        It 'reports the pipeline name and trigger' {
            $script:dmResult.name    | Should -Be 'DataMover.ServiceUpgrade.PROD'
            $script:dmResult.trigger | Should -Be 'none'
        }
    }

    Context 'Prot-style (perCloudScriptFlags, perCloud params)' {
        It 'detects per-cloud script flags as the convention' {
            $script:protResult.cloudConvention | Should -Be 'perCloudScriptFlags'
            $script:protResult.stampParamShape | Should -Be 'perCloud'
            $script:protResult.cloudsDetected  | Should -Contain 'Public'
            $script:protResult.cloudsDetected  | Should -Contain 'Fairfax'
            $script:protResult.cloudsDetected  | Should -Contain 'Mooncake'
        }
        It 'extracts per-cloud stamp defaults with YAML quoting removed' {
            $script:protResult.perCloudDefaults.Public.stamps   | Should -Be 'eus-01,we-01'
            $script:protResult.perCloudDefaults.Public.regions  | Should -Be 'eastus,westeurope'
            $script:protResult.perCloudDefaults.Fairfax.stamps  | Should -Be 'usgv-01'
            $script:protResult.perCloudDefaults.Fairfax.regions | Should -Be 'usgovvirginia'
        }
        It 'extracts the Prot SDS filename' {
            $script:protResult.sdsHint.fileName | Should -Be 'ServiceDatacenterSettingsConfigActPass.json'
        }
        It 'resolves Prot self-repo' {
            $script:protResult.selfRepo.name | Should -Be 'Mgmt-RecoverySvcs-Prot'
        }
    }

    Context 'Inputs' {
        It 'throws on a missing YAML path' {
            { & $script:scriptPath -YamlPath (Join-Path $TestDrive 'missing.yml') } |
                Should -Throw '*not found*'
        }
        It 'works against real DataMover ServiceUpgrade YAML when present' -Skip:(-not (Test-Path 'Q:\Mgmt-RecoverySvcs-DataMover\.pipelines\OneBranch.DataMover.ServiceUpgrade.PROD.yml')) {
            $r = & $script:scriptPath -YamlPath 'Q:\Mgmt-RecoverySvcs-DataMover\.pipelines\OneBranch.DataMover.ServiceUpgrade.PROD.yml'
            $r.cloudConvention                | Should -Be 'stageHardcoded'
            $r.cloudsDetected                 | Should -Be @('Public')
            $r.sdsHint.fileName               | Should -Be 'ServiceDatacenterSettingsConfig.json'
            $r.sdsHint.repoPath               | Should -Be 'src/ServiceFabric/Deployment'
            $r.selfRepo.name                  | Should -Be 'Mgmt-RecoverySvcs-DataMover'
            $r.selfRepo.baseBranch            | Should -Be 'develop'
            $r.ev2.taskVersion                | Should -Be 2
            $r.ev2.endpointProviderType       | Should -Be 'ApprovalService'
            $r.ev2.approvalServiceEnvironment | Should -Be 'Production'
        }
    }
}
