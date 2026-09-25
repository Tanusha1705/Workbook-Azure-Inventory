const fs = require('fs');
let g = JSON.parse(fs.readFileSync('galleryTemplate/template.json', 'utf8'));

let allSiblings = null;
let foundIdx = null;

// Find the Networking Details Tabs links item and its parent array
function findNsgLinks(items) {
  for (let idx = 0; idx < items.length; idx++) {
    const i = items[idx];
    if (i.name === 'links - Networking Details - Tabs') {
      allSiblings = items;
      foundIdx = idx;
      return;
    }
    if (i.content && i.content.items) findNsgLinks(i.content.items);
  }
}
findNsgLinks(g.items);

if (!allSiblings) { console.error('Could not find Networking Details Tabs!'); process.exit(1); }

// Find the "text - End Networking" item index (we inject before it)
const endNetworkingIdx = allSiblings.findIndex(i => i.name === 'text - End Networking');
console.log('End Networking at index:', endNetworkingIdx);

// The links item
const linksItem = allSiblings[foundIdx];

// New resources to add as tabs
const newResources = [
  {
    id: 'nd-vnetlinks',
    label: 'VNet Links',
    subTarget: 'vnetlinks',
    query: `resources\r\n| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Virtual Network Link'] = id, Location=location, ['Registration Enabled']=tostring(properties.registrationEnabled), ['Virtual Network']=tostring(properties.virtualNetwork.id)`
  },
  {
    id: 'nd-networkwatcher',
    label: 'Network Watchers',
    subTarget: 'networkwatcher',
    query: `resources\r\n| where type =~ 'microsoft.network/networkwatchers'\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Network Watcher'] = id, Location=location, State=tostring(properties.provisioningState)`
  },
  {
    id: 'nd-bastion',
    label: 'Bastion Hosts 💲',
    subTarget: 'bastion',
    query: `resources\r\n| where type =~ 'microsoft.network/bastionhosts'\r\n| extend Sku = tostring(sku.name)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Bastion Host'] = id, Location=location, Sku`
  },
  {
    id: 'nd-flowlogs',
    label: 'Flow Logs',
    subTarget: 'flowlogs',
    query: `resources\r\n| where type =~ 'microsoft.network/networkwatchers/flowlogs'\r\n| extend Enabled = tostring(properties.enabled)\r\n| extend StorageId = tostring(properties.storageId)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Flow Log'] = id, Location=location, Enabled, ['Storage Account']=StorageId`
  },
  {
    id: 'nd-localgw',
    label: 'Local Network Gateways',
    subTarget: 'localgw',
    query: `resources\r\n| where type =~ 'microsoft.network/localnetworkgateways'\r\n| extend GatewayIP = tostring(properties.gatewayIpAddress)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Local Network Gateway'] = id, Location=location, ['Gateway IP']=GatewayIP`
  },
  {
    id: 'nd-connections',
    label: 'Connections',
    subTarget: 'connections',
    query: `resources\r\n| where type =~ 'microsoft.network/connections'\r\n| extend ConnectionType = tostring(properties.connectionType)\r\n| extend ConnectionStatus = tostring(properties.connectionStatus)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), Connection=id, Location=location, ConnectionType, ConnectionStatus`
  },
  {
    id: 'nd-asg',
    label: 'Application Security Groups',
    subTarget: 'asg',
    query: `resources\r\n| where type =~ 'microsoft.network/applicationsecuritygroups'\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['App Security Group']=id, Location=location`
  },
  {
    id: 'nd-dnsresolver',
    label: 'DNS Private Resolvers',
    subTarget: 'dnsresolver',
    query: `resources\r\n| where type =~ 'microsoft.network/dnsresolvers'\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['DNS Resolver']=id, Location=location, State=tostring(properties.resourceState)`
  },
  {
    id: 'nd-publicipprefix',
    label: 'Public IP Prefixes 💲',
    subTarget: 'publicipprefix',
    query: `resources\r\n| where type =~ 'microsoft.network/publicipprefixes'\r\n| extend Sku = tostring(sku.name)\r\n| extend PrefixLength = tostring(properties.prefixLength)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Public IP Prefix']=id, Location=location, Sku, ['Prefix Length']=PrefixLength`
  },
  {
    id: 'nd-frontdoor',
    label: 'Front Door 💲',
    subTarget: 'frontdoor',
    query: `resources\r\n| where type =~ 'microsoft.network/frontdoors' or type =~ 'microsoft.cdn/profiles'\r\n| extend Sku = tostring(sku.name)\r\n| extend State = tostring(properties.resourceState)\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Front Door']=id, Location=location, Sku, State`
  },
  {
    id: 'nd-serviceendpointpolicy',
    label: 'Service Endpoint Policies',
    subTarget: 'serviceendpointpolicy',
    query: `resources\r\n| where type =~ 'microsoft.network/serviceendpointpolicies'\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['Service Endpoint Policy']=id, Location=location`
  },
  {
    id: 'nd-dnszones',
    label: 'DNS Zones',
    subTarget: 'dnszones',
    query: `resources\r\n| where type =~ 'microsoft.network/dnszones'\r\n| extend RecordSets = properties.numberOfRecordSets\r\n| project subscriptionId, ['Resource group'] = strcat('/subscriptions/', subscriptionId, '/resourceGroups/', resourceGroup), ['DNS Zone']=id, Location=location, ['Record Sets']=RecordSets`
  }
];

// 1. Add new tabs to links item
newResources.forEach((res, idx) => {
  linksItem.content.links.push({
    id: `nd-link-${res.id}`,
    cellValue: 'network',
    linkTarget: 'parameter',
    linkLabel: res.label,
    subTarget: res.subTarget,
    style: 'link'
  });
});

// 2. Build new query items with correct conditionalVisibilities pattern
const newQueryItems = newResources.map(res => ({
  type: 3,
  content: {
    version: 'KqlItem/1.0',
    query: res.query,
    size: 2,
    title: res.label,
    queryType: 1,
    resourceType: 'microsoft.resourcegraph/resources',
    crossComponentResources: ['{Subscriptions}'],
    visualization: 'table',
    gridSettings: {
      formatters: [
        {
          columnMatch: '$gen_group',
          formatter: 13,
          formatOptions: { linkTarget: 'Resource', showIcon: true }
        },
        {
          columnMatch: 'subscriptionId',
          formatter: 5,
          formatOptions: { linkTarget: 'Resource' }
        },
        {
          columnMatch: 'Resource group',
          formatter: 13,
          formatOptions: { linkTarget: 'Resource', showIcon: true }
        }
      ],
      filter: true,
      hierarchySettings: {
        treeType: 1,
        groupBy: ['subscriptionId'],
        expandTopLevel: false
      },
      labelSettings: []
    },
    showExportToExcel: true
  },
  conditionalVisibilities: [
    { parameterName: 'selectedTab', comparison: 'isEqualTo', value: 'network' },
    { parameterName: 'network', comparison: 'isEqualTo', value: res.subTarget }
  ],
  name: `query - Networking Details - ${res.label}`
}));

// 3. Insert new query items BEFORE the "text - End Networking" item
allSiblings.splice(endNetworkingIdx, 0, ...newQueryItems);

// 4. Save both files
fs.writeFileSync('galleryTemplate/template.json', JSON.stringify(g, null, 2));

const arm = JSON.parse(fs.readFileSync('armTemplate/template.json', 'utf8'));
arm.resources[0].properties.serializedData = JSON.stringify(g);
fs.writeFileSync('armTemplate/template.json', JSON.stringify(arm, null, 2));

console.log(`Done! Added ${newResources.length} new tabs to Networking Details.`);
console.log('New tab labels:', newResources.map(r => r.label).join(', '));
