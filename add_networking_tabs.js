const fs = require('fs');
let g = JSON.parse(fs.readFileSync('galleryTemplate/template.json', 'utf8'));

let networkGroup = null;
function findNetworking(items) {
  for (let i of items) {
    if (i.name === 'group - Networking') { networkGroup = i; return; }
    if (i.content && i.content.items) findNetworking(i.content.items);
  }
}
findNetworking(g.items);

const linksTab = networkGroup.content.items.find(i => i.name === 'links - Networking Tabs');

// --- New resource types to add ---
const newResources = [
  {
    label: 'Virtual Network Links',
    subTarget: 'vnetlinks',
    groupName: 'group - Networking - Virtual Network Links',
    title: '## Virtual Network Links',
    resourceType: 'microsoft.network/privatednszones/virtualnetworklinks',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks'\r\n| project subscriptionId, Resource=id, resourceGroup, location, tags, Details=pack_all()`
  },
  {
    label: 'Network Watchers',
    subTarget: 'networkwatcher',
    groupName: 'group - Networking - Network Watchers',
    title: '## Network Watchers',
    resourceType: 'microsoft.network/networkwatchers',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/networkwatchers'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/networkwatchers'\r\n| project subscriptionId, Resource=id, resourceGroup, location, tags, Details=pack_all()`
  },
  {
    label: 'Bastion Hosts',
    subTarget: 'bastion',
    groupName: 'group - Networking - Bastion Hosts',
    title: '## Bastion Hosts',
    resourceType: 'microsoft.network/bastionhosts',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/bastionhosts'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/bastionhosts'\r\n| extend Sku = tostring(sku.name)\r\n| project subscriptionId, Resource=id, resourceGroup, location, Sku, tags, Details=pack_all()`
  },
  {
    label: 'Flow Logs',
    subTarget: 'flowlogs',
    groupName: 'group - Networking - Flow Logs',
    title: '## Flow Logs',
    resourceType: 'microsoft.network/networkwatchers/flowlogs',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/networkwatchers/flowlogs'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/networkwatchers/flowlogs'\r\n| extend Enabled = tostring(properties.enabled)\r\n| extend StorageId = tostring(properties.storageId)\r\n| project subscriptionId, Resource=id, resourceGroup, location, Enabled, StorageId, tags, Details=pack_all()`
  },
  {
    label: 'Local Network Gateways',
    subTarget: 'localgw',
    groupName: 'group - Networking - Local Network Gateways',
    title: '## Local Network Gateways',
    resourceType: 'microsoft.network/localnetworkgateways',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/localnetworkgateways'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/localnetworkgateways'\r\n| extend GatewayIPAddress = tostring(properties.gatewayIpAddress)\r\n| project subscriptionId, Resource=id, resourceGroup, location, GatewayIPAddress, tags, Details=pack_all()`
  },
  {
    label: 'Connections',
    subTarget: 'connections',
    groupName: 'group - Networking - Connections',
    title: '## VPN / ExpressRoute Connections',
    resourceType: 'microsoft.network/connections',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/connections'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/connections'\r\n| extend ConnectionType = tostring(properties.connectionType)\r\n| extend ConnectionStatus = tostring(properties.connectionStatus)\r\n| project subscriptionId, Resource=id, resourceGroup, location, ConnectionType, ConnectionStatus, tags, Details=pack_all()`
  },
  {
    label: 'Application Security Groups',
    subTarget: 'asg',
    groupName: 'group - Networking - Application Security Groups',
    title: '## Application Security Groups',
    resourceType: 'microsoft.network/applicationsecuritygroups',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/applicationsecuritygroups'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/applicationsecuritygroups'\r\n| project subscriptionId, Resource=id, resourceGroup, location, tags, Details=pack_all()`
  },
  {
    label: 'DNS Private Resolvers',
    subTarget: 'dnsprivateresolvers',
    groupName: 'group - Networking - DNS Private Resolvers',
    title: '## DNS Private Resolvers',
    resourceType: 'microsoft.network/dnsprivatezones',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/dnsresolvers'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/dnsresolvers'\r\n| project subscriptionId, Resource=id, resourceGroup, location, tags, Details=pack_all()`
  },
  {
    label: 'Public IP Prefixes',
    subTarget: 'publicipprefixes',
    groupName: 'group - Networking - Public IP Prefixes',
    title: '## Public IP Prefixes',
    resourceType: 'microsoft.network/publicipprefixes',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/publicipprefixes'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/publicipprefixes'\r\n| extend Sku = tostring(sku.name)\r\n| extend PrefixLength = tostring(properties.prefixLength)\r\n| project subscriptionId, Resource=id, resourceGroup, location, Sku, PrefixLength, tags, Details=pack_all()`
  },
  {
    label: 'Front Door 💲',
    subTarget: 'frontdoor',
    groupName: 'group - Networking - Front Door',
    title: '## Azure Front Door',
    resourceType: 'microsoft.network/frontdoors',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/frontdoors' or type =~ 'microsoft.cdn/profiles'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/frontdoors' or type =~ 'microsoft.cdn/profiles'\r\n| extend Sku = tostring(sku.name)\r\n| extend State = tostring(properties.resourceState)\r\n| project subscriptionId, Resource=id, resourceGroup, location, Sku, State, tags, Details=pack_all()`
  },
  {
    label: 'Service Endpoint Policies',
    subTarget: 'serviceendpointpolicy',
    groupName: 'group - Networking - Service Endpoint Policies',
    title: '## Service Endpoint Policies',
    resourceType: 'microsoft.network/serviceendpointpolicies',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/serviceendpointpolicies'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/serviceendpointpolicies'\r\n| project subscriptionId, Resource=id, resourceGroup, location, tags, Details=pack_all()`
  },
  {
    label: 'DNS Zones',
    subTarget: 'dnszones',
    groupName: 'group - Networking - DNS Zones',
    title: '## DNS Zones',
    resourceType: 'microsoft.network/dnszones',
    countQuery: `resources\r\n| where type =~ 'microsoft.network/dnszones'\r\n| summarize count()`,
    listQuery: `resources\r\n| where type =~ 'microsoft.network/dnszones'\r\n| extend NumberOfRecordSets = properties.numberOfRecordSets\r\n| project subscriptionId, Resource=id, resourceGroup, location, NumberOfRecordSets, tags, Details=pack_all()`
  }
];

// Build group items from template
function makeGroup(res) {
  return {
    type: 12,
    content: {
      version: "NotebookGroup/1.0",
      groupType: "editable",
      items: [
        {
          type: 1,
          content: { json: res.title },
          name: `text - Title - ${res.label}`
        },
        {
          type: 3,
          content: {
            version: "KqlItem/1.0",
            query: res.listQuery,
            size: 0,
            queryType: 1,
            resourceType: "microsoft.resourcegraph/resources",
            crossComponentResources: ["{Subscription}"],
            gridSettings: {
              formatters: [],
              filter: true,
              labelSettings: []
            },
            title: res.label,
            showExportToExcel: true
          },
          name: `query - ${res.label}`
        }
      ]
    },
    conditionalVisibility: {
      parameterName: "networkingTab",
      comparison: "isEqualTo",
      value: res.subTarget
    },
    name: res.groupName
  };
}

// Add new tabs to the links
const newLinks = newResources.map((res, idx) => ({
  id: `new-net-tab-${idx}-${Date.now()}`,
  cellValue: "networkingTab",
  linkTarget: "parameter",
  linkLabel: res.label,
  subTarget: res.subTarget,
  style: "link"
}));

linksTab.content.links.push(...newLinks);

// Add new groups to the networking group content
newResources.forEach(res => {
  networkGroup.content.items.push(makeGroup(res));
});

// Save both gallery and arm templates
fs.writeFileSync('galleryTemplate/template.json', JSON.stringify(g, null, 2));

const arm = JSON.parse(fs.readFileSync('armTemplate/template.json', 'utf8'));
arm.resources[0].properties.serializedData = JSON.stringify(g);
fs.writeFileSync('armTemplate/template.json', JSON.stringify(arm, null, 2));

console.log(`Done! Added ${newResources.length} new networking tabs.`);
