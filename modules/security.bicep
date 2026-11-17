// Log Analytics + Microsoft Sentinel + Windows Security event collection (AMA/DCR)
// + three analytics rules built around help desk / identity attack scenarios.

param location string
param tags object
param alertEmail string

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'jt-law-secops'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Installing the Sentinel solution creates the SecurityEvent table up front.
// Without it, the DCR and analytics rules below fail because the table doesn't exist yet.
resource sentinelSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${law.name})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: law.id
  }
  plan: {
    name: 'SecurityInsights(${law.name})'
    publisher: 'Microsoft'
    product: 'OMSGallery/SecurityInsights'
    promotionCode: ''
  }
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  scope: law
  name: 'default'
  properties: {}
  dependsOn: [
    sentinelSolution
  ]
}

// Collect only the Security events the detections need (keeps ingestion tiny).
//   4624/4625 logon success/failure   4740 account locked out
//   4720 user created                 4724 password reset by admin
//   4767 account unlocked             4728/4732/4756 member added to security group
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'jt-dcr-windows-security'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'identity-security-events'
          streams: [
            'Microsoft-SecurityEvent'
          ]
          xPathQueries: [
            'Security!*[System[(EventID=4624 or EventID=4625 or EventID=4720 or EventID=4724 or EventID=4728 or EventID=4732 or EventID=4740 or EventID=4756 or EventID=4767)]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law'
          workspaceResourceId: law.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-SecurityEvent'
        ]
        destinations: [
          'law'
        ]
      }
    ]
  }
  dependsOn: [
    sentinel
  ]
}

// --- Sentinel analytics rules -------------------------------------------------
resource ruleBruteForce 'Microsoft.SecurityInsights/alertRules@2024-03-01' = {
  scope: law
  name: guid(law.id, 'jt-bruteforce')
  kind: 'Scheduled'
  properties: {
    displayName: 'JT Lab - Possible password spray / brute force (5+ failed logons in 10 min)'
    description: 'Same account failed to log on 5 or more times within 10 minutes.'
    severity: 'Medium'
    enabled: true
    query: '''
SecurityEvent
| where EventID == 4625
| summarize FailedAttempts = count(), Workstations = make_set(WorkstationName), SourceIPs = make_set(IpAddress)
    by TargetAccount, Computer, bin(TimeGenerated, 10m)
| where FailedAttempts >= 5
'''
    queryFrequency: 'PT5M'
    queryPeriod: 'PT15M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [
      'CredentialAccess'
    ]
    techniques: [
      'T1110'
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'AllEntities'
      }
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'FullName'
            columnName: 'TargetAccount'
          }
        ]
      }
      {
        entityType: 'Host'
        fieldMappings: [
          {
            identifier: 'FullName'
            columnName: 'Computer'
          }
        ]
      }
    ]
  }
  dependsOn: [
    sentinel
  ]
}

resource ruleLockout 'Microsoft.SecurityInsights/alertRules@2024-03-01' = {
  scope: law
  name: guid(law.id, 'jt-lockout')
  kind: 'Scheduled'
  properties: {
    displayName: 'JT Lab - Domain account locked out'
    description: 'Event 4740 on a domain controller. Correlate with the brute-force rule before unlocking.'
    severity: 'Low'
    enabled: true
    query: '''
SecurityEvent
| where EventID == 4740
// For 4740, TargetDomainName carries the caller computer (where the bad passwords came from).
| project TimeGenerated, LockedAccount = TargetUserName, CallerComputer = TargetDomainName, DomainController = Computer
'''
    queryFrequency: 'PT5M'
    queryPeriod: 'PT5M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [
      'CredentialAccess'
    ]
    techniques: [
      'T1110'
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: false
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'AllEntities'
      }
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'FullName'
            columnName: 'LockedAccount'
          }
        ]
      }
    ]
  }
  dependsOn: [
    sentinel
  ]
}

resource rulePrivGroup 'Microsoft.SecurityInsights/alertRules@2024-03-01' = {
  scope: law
  name: guid(law.id, 'jt-privgroup')
  kind: 'Scheduled'
  properties: {
    displayName: 'JT Lab - Member added to a privileged AD group'
    description: 'Someone was added to Domain Admins, Enterprise Admins, Schema Admins or Administrators.'
    severity: 'High'
    enabled: true
    query: '''
SecurityEvent
| where EventID in (4728, 4732, 4756)
| where TargetUserName in ("Domain Admins", "Enterprise Admins", "Schema Admins", "Administrators")
| project TimeGenerated, Group = TargetUserName, AddedMember = MemberName, ChangedBy = SubjectAccount, Computer
'''
    queryFrequency: 'PT5M'
    queryPeriod: 'PT5M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: [
      'PrivilegeEscalation'
      'Persistence'
    ]
    techniques: [
      'T1098'
    ]
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: false
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'AllEntities'
      }
    }
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'FullName'
            columnName: 'ChangedBy'
          }
        ]
      }
      {
        entityType: 'Host'
        fieldMappings: [
          {
            identifier: 'FullName'
            columnName: 'Computer'
          }
        ]
      }
    ]
  }
  dependsOn: [
    sentinel
  ]
}

// --- Azure Monitor: email on NSG rule changes ----------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'jt-ag-secops'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'jt-secops'
    enabled: true
    emailReceivers: [
      {
        name: 'Owner-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource nsgChangeAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'jt-alert-nsg-rule-change'
  location: 'global'
  tags: tags
  properties: {
    description: 'Someone created or edited an NSG rule in the lab.'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/securityRules/write'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output dcrId string = dcr.id
