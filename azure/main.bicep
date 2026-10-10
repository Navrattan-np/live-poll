targetScope = 'resourceGroup'

@description('Region for all resources. Use a region where Azure Container Apps is available (e.g. eastus, westeurope).')
param location string = resourceGroup().location

@description('Base name; a short unique suffix is appended automatically to guarantee global uniqueness.')
@minLength(3)
@maxLength(16)
param baseName string = 'livepoll'

@secure()
@description('Shared secret for the /host endpoints. deploy.sh generates and reuses one automatically.')
param hostKey string

@description('Tag of the livepoll image in ACR. CI deploys with the commit SHA; the first deploy uses this.')
param imageTag string = 'v1'

@description('Comma-separated public URLs of both servers, used by /join for round-robin. Filled in by deploy.sh on the last pass.')
param peers string = ''

@description('False on the first pass: only ACR + environment + redis are created, so the image can be built before the apps start.')
param deployApps bool = true

var suffix = substring(uniqueString(resourceGroup().id), 0, 6)
var names = {
  acr: toLower('${baseName}${suffix}')
  env: toLower('${baseName}-env-${suffix}')
  redis: toLower('${baseName}-redis-${suffix}')
  a: toLower('${baseName}-a-${suffix}')
  b: toLower('${baseName}-b-${suffix}')
}
var instances = [
  { name: names.a, instance: 'A' }
  { name: names.b, instance: 'B' }
]

// ---------- registry ----------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: names.acr
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

// ---------- container apps environment (consumption-only) ----------
resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: names.env
  location: location
  properties: {
    zoneRedundant: false
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

// ---------- redis (internal TCP only, never exposed to the internet) ----------
resource redis 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.redis
  location: location
  properties: {
    environmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 6379
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'redis'
          image: 'redis:7-alpine'
          args: ['redis-server', '--save', '', '--appendonly', 'no']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            {
              type: 'tcp'
              tcpSocket: { port: 6379 }
              initialDelaySeconds: 3
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ---------- the two poll servers ----------
resource pollApps 'Microsoft.App/containerApps@2024-03-01' = [
  for i in instances: if (deployApps) {
    name: i.name
    location: location
    identity: { type: 'SystemAssigned' }
    properties: {
      environmentId: env.id
      configuration: {
        activeRevisionsMode: 'Single'
        secrets: [{ name: 'host-key', value: hostKey }]
        registries: [
          { server: acr.properties.loginServer, identity: 'system' }
        ]
        ingress: {
          external: true
          targetPort: 8000
          transport: 'auto'
          traffic: [{ weight: 100, latestRevision: true }]
        }
      }
      template: {
        containers: [
          {
            name: 'poll'
            image: '${acr.properties.loginServer}/livepoll:${imageTag}'
            env: [
              { name: 'INSTANCE_NAME', value: i.instance }
              { name: 'REDIS_URL', value: 'redis://${names.redis}:6379' }
              { name: 'HOST_KEY', secretRef: 'host-key' }
              { name: 'PEERS', value: peers }
            ]
            resources: { cpu: json('0.25'), memory: '0.5Gi' }
            probes: [
              {
                type: 'http'
                httpGet: { path: '/health', port: 8000 }
                initialDelaySeconds: 5
                periodSeconds: 10
                failureThreshold: 3
              }
            ]
          }
        ]
        scale: { minReplicas: 1, maxReplicas: 1 }
      }
    }
  }
]

// AcrPull so each app pulls with its managed identity (no registry passwords)
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for i in range(0, length(instances)): if (deployApps) {
    name: guid(acr.id, instances[i].name, 'AcrPull')
    scope: acr
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      principalId: pollApps[i].identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output acrName string = acr.name
output redisAppName string = redis.name
output appAName string = deployApps ? pollApps[0].name : ''
output appBName string = deployApps ? pollApps[1].name : ''
output urlA string = deployApps ? 'https://${pollApps[0].properties.configuration.ingress.fqdn}' : ''
output urlB string = deployApps ? 'https://${pollApps[1].properties.configuration.ingress.fqdn}' : ''
