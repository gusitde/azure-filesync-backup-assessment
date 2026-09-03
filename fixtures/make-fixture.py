#!/usr/bin/env python3
"""Generate fixtures/sample-export: a synthetic Export-AzFileSyncEnvironment.ps1 output for a
fictional organization ("Contoso-Prod") with one Storage Sync Service, three sync groups, three
registered servers (one healthy, one broken and out of support, one clustered), two storage
accounts (one weak, one hardened), one Recovery Services vault with a snapshot-only policy,
one failed job, no private networking, and one server-side diagnostic bundle.

Every deliberate defect maps to an assessment rule; tests/run-tests.ps1 asserts the mapping.
Re-run this script whenever the export layout changes:  python fixtures/make-fixture.py
"""
import json, os, shutil

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample-export")
SUB = "11111111-1111-4111-8111-111111111111"
SUBNAME = "Contoso-Prod"
LOC = "westus2"
EXPORTED = "2026-09-03T15:00:00.0000000Z"
RG = f"/subscriptions/{SUB}/resourceGroups/rg-contoso-files"
SSS = f"{RG}/providers/Microsoft.StorageSync/storageSyncServices/sss-contoso-files"
SA1 = f"{RG}/providers/Microsoft.Storage/storageAccounts/stcontosofiles01"
SA2 = f"{RG}/providers/Microsoft.Storage/storageAccounts/stcontosobackup02"
VAULT = f"{RG}/providers/Microsoft.RecoveryServices/vaults/rsv-contoso-westus2"
SRV = lambda n: f"{SSS}/registeredServers/{n}"


def w(rel, obj):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1)


def sync_status(health="Healthy", persistent=0, last="2026-09-03T14:30:00Z", per_item=0):
    return {
        "downloadHealth": "Error" if health != "Healthy" else "Healthy",
        "uploadHealth": "Error" if health != "Healthy" else "Healthy",
        "combinedHealth": health,
        "syncActivity": "PendingUpload" if health != "Healthy" else "None",
        "totalPersistentFilesNotSyncingCount": persistent,
        "lastUpdatedTimestamp": last,
        "uploadStatus": {"lastSyncResult": 0, "lastSyncTimestamp": last, "lastSyncSuccessTimestamp": last, "lastSyncPerItemErrorCount": per_item, "persistentFilesNotSyncingCount": persistent, "transientFilesNotSyncingCount": 0, "filesNotSyncingErrors": []},
        "downloadStatus": {"lastSyncResult": 0, "lastSyncTimestamp": last, "lastSyncSuccessTimestamp": last, "lastSyncPerItemErrorCount": 0, "persistentFilesNotSyncingCount": 0, "transientFilesNotSyncingCount": 0, "filesNotSyncingErrors": []},
    }


def tiering_status(health="Healthy", result=0, low_disk="Disabled", hit=0.95):
    return {
        "lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "health": health, "healthLastUpdatedTimestamp": "2026-09-03T14:00:00Z",
        "lastCloudTieringResult": result, "lastSuccessTimestamp": "2026-09-03T13:00:00Z",
        "spaceSavings": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "volumeSizeBytes": 2199023255552, "totalSizeCloudBytes": 1649267441664, "cachedSizeBytes": 549755813888, "spaceSavingsPercent": 75, "spaceSavingsBytes": 1099511627776},
        "cachePerformance": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "cacheHitBytes": 950, "cacheMissBytes": 50, "cacheHitBytesPercent": 95, "cacheHitRatio": hit},
        "filesNotTiering": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "totalFileCount": 0, "errors": []},
        "volumeFreeSpacePolicyStatus": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "effectiveVolumeFreeSpacePolicy": 20, "currentVolumeFreeSpacePercent": 21},
        "datePolicyStatus": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "tieredFilesMostRecentAccessTimestamp": "2026-07-01T00:00:00Z"},
        "lowDiskMode": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "state": low_disk},
    }


def server_endpoint(group, name, server, path, tiering="on", vfs=20, days=60, sync=None, tier=None):
    return {
        "id": f"{SSS}/syncGroups/{group}/serverEndpoints/{name}", "name": name, "type": "Microsoft.StorageSync/storageSyncServices/syncGroups/serverEndpoints",
        "properties": {
            "serverLocalPath": path, "cloudTiering": tiering, "volumeFreeSpacePercent": vfs, "tierFilesOlderThanDays": days,
            "friendlyName": server, "serverName": server + ".contoso.local", "serverResourceId": SRV(server.lower()),
            "provisioningState": "Succeeded", "lastWorkflowId": "", "lastOperationName": "", "initialDownloadPolicy": "NamespaceThenModifiedFiles",
            "localCacheMode": "UpdateLocallyCachedFiles", "initialUploadPolicy": "Merge",
            "syncStatus": sync or sync_status(), "cloudTieringStatus": tier or (tiering_status() if tiering == "on" else None),
            "recallStatus": {"lastUpdatedTimestamp": "2026-09-03T14:00:00Z", "totalRecallErrorsCount": 0, "recallErrors": []},
        },
    }


def registered_server(name, os_ver, agent, status="Ok", expires="2027-06-01T00:00:00Z", heartbeat="2026-09-03T14:58:00Z", cluster=None):
    p = {
        "serverCertificate": "MIIC...REDACTED-IN-EXPORT...", "agentVersion": agent, "agentVersionStatus": status, "agentVersionExpirationDate": expires,
        "serverOSVersion": os_ver, "serverManagementErrorCode": 0, "lastHeartBeat": heartbeat, "provisioningState": "Succeeded",
        "serverRole": "Standalone" if not cluster else "ClusterNode", "clusterId": "", "clusterName": cluster or "", "serverId": "aaaa-" + name.lower(),
        "storageSyncServiceUid": "sss-uid", "lastWorkflowId": "", "lastOperationName": "", "discoveryEndpointUri": "https://x.afs.azure.net", "resourceLocation": LOC,
        "serviceLocation": LOC, "friendlyName": name, "managementEndpointUri": "https://x.afs.azure.net", "monitoringEndpointUri": "https://x.afs.azure.net", "monitoringConfiguration": "",
        "serverName": name + ".contoso.local", "activeAuthType": "Certificate",
    }
    return {"id": SRV(name.lower()), "name": name.lower(), "type": "Microsoft.StorageSync/storageSyncServices/registeredServers", "properties": p}


def cloud_endpoint(group, name, account_id, share, enum="2026-09-03T02:00:00Z"):
    ces = {"lastCompletedEnumeration": {"startedTimestamp": enum, "completedTimestamp": enum, "namespaceFilesCount": 100000, "namespaceDirectoriesCount": 8000, "namespaceSizeBytes": 1099511627776, "nextRunTimestamp": "2026-09-04T02:00:00Z"}} if enum else {}
    return {"id": f"{SSS}/syncGroups/{group}/cloudEndpoints/{name}", "name": name, "type": "Microsoft.StorageSync/storageSyncServices/syncGroups/cloudEndpoints",
            "properties": {"storageAccountResourceId": account_id, "azureFileShareName": share, "storageAccountTenantId": "tenant", "partnershipId": "p", "friendlyName": share, "backupEnabled": "false", "provisioningState": "Succeeded", "lastWorkflowId": "", "lastOperationName": "", "changeEnumerationStatus": ces}}


def share(account_id, name, quota, used_gib, tier="TransactionOptimized"):
    return {"id": f"{account_id}/fileServices/default/shares/{name}", "name": name, "type": "Microsoft.Storage/storageAccounts/fileServices/shares", "etag": "x",
            "properties": {"leaseStatus": "unlocked", "leaseState": "available", "signedIdentifiers": [], "shareUsageBytes": int(used_gib * 1024 ** 3), "accessTier": tier, "accessTierChangeTime": "2025-01-01T00:00:00Z", "lastModifiedTime": "2026-09-01T00:00:00Z", "shareQuota": quota, "enabledProtocols": "SMB"}}


def metrics_recall():
    return {"StorageSyncRecallTotalSizeBytes": {"cost": 0, "timespan": "2026-08-27T15:00:00Z/2026-09-03T15:00:00Z", "interval": "P1D", "value": [{"id": SSS + "/providers/Microsoft.Insights/metrics/StorageSyncRecallTotalSizeBytes", "type": "Microsoft.Insights/metrics", "name": {"value": "StorageSyncRecallTotalSizeBytes", "localizedValue": "Cloud tiering recall size"}, "unit": "Bytes", "timeseries": [{"metadatavalues": [{"name": {"value": "ServerName"}, "value": "FS01"}], "data": [{"timeStamp": "2026-09-01T00:00:00Z", "total": 644245094400}, {"timeStamp": "2026-09-02T00:00:00Z", "total": 1073741824}]}]}]}}


if os.path.exists(ROOT):
    shutil.rmtree(ROOT)

# ---- Storage Sync Service ---------------------------------------------------------------
d = f"storagesync/{SUBNAME}__sss-contoso-files"
w(f"{d}/service.json", {"id": SSS, "name": "sss-contoso-files", "type": "Microsoft.StorageSync/storageSyncServices", "location": LOC, "tags": {}, "properties": {"incomingTrafficPolicy": "AllowAllTraffic", "storageSyncServiceStatus": 0, "storageSyncServiceUid": "sss-uid", "provisioningState": "Succeeded", "privateEndpointConnections": [], "useIdentity": False}})
w(f"{d}/syncgroups.json", [{"id": f"{SSS}/syncGroups/{g}", "name": g, "type": "Microsoft.StorageSync/storageSyncServices/syncGroups", "properties": {"uniqueId": g, "syncGroupStatus": "0"}} for g in ["sg-home", "sg-dept", "sg-archive"]])
w(f"{d}/cloudendpoints.json", [
    cloud_endpoint("sg-home", "ce-home", SA1, "home-drives"),
    cloud_endpoint("sg-dept", "ce-dept", SA1, "dept-shares"),
    cloud_endpoint("sg-archive", "ce-archive", SA1, "archive", enum=None),
])
w(f"{d}/serverendpoints.json", [
    server_endpoint("sg-home", "se-fs01-home", "FS01", "D:\\Home", vfs=20, days=60),
    server_endpoint("sg-dept", "se-fs01-dept", "FS01", "E:\\Dept", vfs=5, days=30,
                    sync=sync_status("Error", persistent=12, last="2026-09-01T03:00:00Z", per_item=12),
                    tier=tiering_status("Error", result=-2147024784, low_disk="Enabled", hit=0.55)),
    server_endpoint("sg-dept", "se-fs02-data", "FS02", "C:\\Data", tiering="off"),
    server_endpoint("sg-dept", "se-fs02-sub", "FS02", "C:\\Data\\Sub", tiering="off"),
])
w(f"{d}/registeredservers.json", [
    registered_server("FS01", "10.0.20348.2700", "19.1.0.0", expires="2026-10-15T00:00:00Z"),
    registered_server("FS02", "6.3.9600.0", "17.0.0.0", status="Expired", expires="2026-06-01T00:00:00Z", heartbeat="2026-09-01T00:00:00Z"),
    registered_server("FS03", "10.0.14393.7000", "20.0.0.0", cluster="CL01"),
])
w(f"{d}/privateendpointconnections.json", [])
w(f"{d}/diagnostics.json", [])
w(f"{d}/roleassignments.json", [])
w(f"{d}/locks.json", [])
w(f"{d}/metrics.json", metrics_recall())

# ---- Storage accounts -------------------------------------------------------------------
d1 = f"storage/{SUBNAME}__stcontosofiles01"
w(f"{d1}/account.json", {"id": SA1, "name": "stcontosofiles01", "type": "Microsoft.Storage/storageAccounts", "location": LOC, "tags": {}, "sku": {"name": "Standard_LRS", "tier": "Standard"}, "kind": "StorageV2",
  "properties": {"keyCreationTime": {"key1": "2024-01-15T10:00:00.0000000Z", "key2": "2024-01-15T10:00:00.0000000Z"}, "privateEndpointConnections": [], "minimumTlsVersion": "TLS1_0", "allowBlobPublicAccess": True, "allowCrossTenantReplication": False,
                 "networkAcls": {"bypass": "AzureServices", "virtualNetworkRules": [], "ipRules": [], "defaultAction": "Allow"}, "supportsHttpsTrafficOnly": True,
                 "encryption": {"services": {"file": {"keyType": "Account", "enabled": True, "lastEnabledTime": "2024-01-15T10:00:00Z"}, "blob": {"keyType": "Account", "enabled": True, "lastEnabledTime": "2024-01-15T10:00:00Z"}}, "keySource": "Microsoft.Storage"},
                 "accessTier": "Hot", "provisioningState": "Succeeded", "creationTime": "2024-01-15T10:00:00Z", "primaryLocation": LOC, "statusOfPrimary": "available", "largeFileSharesState": "Disabled",
                 "azureFilesIdentityBasedAuthentication": {"directoryServiceOptions": "None"}, "publicNetworkAccess": "Enabled"}})
w(f"{d1}/fileservice.json", {"id": SA1 + "/fileServices/default", "name": "default", "type": "Microsoft.Storage/storageAccounts/fileServices", "sku": {"name": "Standard_LRS", "tier": "Standard"}, "properties": {"protocolSettings": {"smb": {}}, "cors": {"corsRules": []}, "shareDeleteRetentionPolicy": {"enabled": False}}})
w(f"{d1}/shares.json", {"shares": [share(SA1, "home-drives", 5120, 4915), share(SA1, "dept-shares", 10240, 2048), share(SA1, "archive", 1024, 100, tier="Cool"), share(SA1, "scans", 1024, 900)], "snapshots": [],
                        "softDeleted": [{"id": SA1 + "/fileServices/default/shares/old-share_123", "name": "old-share", "properties": {"deleted": True, "deletedTime": "2026-08-25T00:00:00Z", "remainingRetentionDays": 6, "shareQuota": 100, "version": "123"}}]})
w(f"{d1}/diagnostics-account.json", [])
w(f"{d1}/diagnostics-fileservice.json", [])
w(f"{d1}/roleassignments.json", [{"id": SA1 + "/providers/Microsoft.Authorization/roleAssignments/ra1", "scope": SA1, "roleName": "Owner", "roleDefinitionId": "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635", "principalId": "user-guid", "principalType": "User", "condition": None, "createdOn": "2025-01-01T00:00:00Z"},
                                    {"id": SA1 + "/providers/Microsoft.Authorization/roleAssignments/ra2", "scope": SA1, "roleName": "Reader and Data Access", "roleDefinitionId": "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/c12c1c16-33a1-487b-954d-41c89c60f349", "principalId": "afs-sp-guid", "principalType": "ServicePrincipal", "condition": None, "createdOn": "2025-01-01T00:00:00Z"}])
w(f"{d1}/locks.json", [])
w(f"{d1}/defender.json", None)
w(f"{d1}/metrics.json", None)

d2 = f"storage/{SUBNAME}__stcontosobackup02"
w(f"{d2}/account.json", {"id": SA2, "name": "stcontosobackup02", "type": "Microsoft.Storage/storageAccounts", "location": LOC, "tags": {"owner": "itd-storage", "environment": "prod"}, "sku": {"name": "Standard_GRS", "tier": "Standard"}, "kind": "StorageV2",
  "properties": {"keyCreationTime": {"key1": "2026-06-01T10:00:00.0000000Z", "key2": "2026-06-01T10:00:00.0000000Z"}, "keyPolicy": {"keyExpirationPeriodInDays": 180}, "privateEndpointConnections": [{"id": SA2 + "/privateEndpointConnections/pe1", "name": "pe1", "properties": {"privateEndpoint": {"id": RG + "/providers/Microsoft.Network/privateEndpoints/pe-stcontosobackup02-file"}, "privateLinkServiceConnectionState": {"status": "Approved"}}}],
                 "minimumTlsVersion": "TLS1_2", "allowBlobPublicAccess": False, "allowCrossTenantReplication": False, "allowSharedKeyAccess": True,
                 "networkAcls": {"bypass": "AzureServices", "virtualNetworkRules": [], "ipRules": [{"value": "203.0.113.10", "action": "Allow"}], "defaultAction": "Deny"}, "supportsHttpsTrafficOnly": True,
                 "encryption": {"services": {"file": {"keyType": "Account", "enabled": True}}, "keySource": "Microsoft.Keyvault", "keyvaultproperties": {"keyname": "sa-key", "keyvaulturi": "https://kv.vault.azure.net/"}},
                 "accessTier": "Hot", "provisioningState": "Succeeded", "largeFileSharesState": "Enabled", "azureFilesIdentityBasedAuthentication": {"directoryServiceOptions": "AD", "activeDirectoryProperties": {"domainName": "contoso.local"}}, "publicNetworkAccess": "Enabled"}})
w(f"{d2}/fileservice.json", {"id": SA2 + "/fileServices/default", "name": "default", "properties": {"protocolSettings": {"smb": {"versions": "SMB3.0;SMB3.1.1", "authenticationMethods": "Kerberos", "kerberosTicketEncryption": "AES-256", "channelEncryption": "AES-128-GCM;AES-256-GCM"}}, "shareDeleteRetentionPolicy": {"enabled": True, "days": 14}}})
w(f"{d2}/shares.json", {"shares": [share(SA2, "gis", 10240, 3000)], "snapshots": [{"id": SA2 + "/fileServices/default/shares/gis", "name": "gis", "properties": {"snapshotTime": "2026-09-02T02:00:00Z", "shareQuota": 10240}}], "softDeleted": []})
w(f"{d2}/diagnostics-account.json", [])
w(f"{d2}/diagnostics-fileservice.json", [{"id": SA2 + "/fileServices/default/providers/microsoft.insights/diagnosticSettings/to-law", "name": "to-law", "properties": {"workspaceId": "/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law", "logs": [{"category": "StorageDelete", "enabled": True}]}}])
w(f"{d2}/roleassignments.json", [])
w(f"{d2}/locks.json", [{"id": SA2 + "/providers/Microsoft.Authorization/locks/no-delete", "name": "no-delete", "properties": {"level": "CanNotDelete"}}])
w(f"{d2}/defender.json", {"id": SA2 + "/providers/Microsoft.Security/defenderForStorageSettings/current", "properties": {"isEnabled": True}})
w(f"{d2}/metrics.json", None)

w(f"defender/{SUBNAME}-pricing-StorageAccounts.json", {"id": f"/subscriptions/{SUB}/providers/Microsoft.Security/pricings/StorageAccounts", "name": "StorageAccounts", "properties": {"pricingTier": "Free"}})
w(f"locks/{SUBNAME}.json", [])

# ---- Backup ------------------------------------------------------------------------------
dv = f"backup/{SUBNAME}__rsv-contoso-westus2"
w(f"{dv}/vault.json", {"id": VAULT, "name": "rsv-contoso-westus2", "type": "Microsoft.RecoveryServices/vaults", "location": LOC, "tags": {}, "sku": {"name": "RS0", "tier": "Standard"},
  "properties": {"provisioningState": "Succeeded", "privateEndpointStateForBackup": "None", "privateEndpointStateForSiteRecovery": "None", "publicNetworkAccess": "Enabled",
                 "securitySettings": {"softDeleteSettings": {"softDeleteState": "Enabled", "softDeleteRetentionPeriodInDays": 14, "enhancedSecurityState": "Disabled"}, "immutabilitySettings": {"state": "Disabled"}, "multiUserAuthorization": "Disabled"},
                 "redundancySettings": {"standardTierStorageRedundancy": "LocallyRedundant", "crossRegionRestore": "Disabled"},
                 "monitoringSettings": {"azureMonitorAlertSettings": {"alertsForAllJobFailures": "Disabled"}, "classicAlertSettings": {"alertsForCriticalOperations": "Enabled"}}}})
w(f"{dv}/vaultconfig.json", {"id": VAULT + "/backupconfig/vaultconfig", "properties": {"enhancedSecurityState": "Disabled", "softDeleteFeatureState": "Enabled", "isSoftDeleteFeatureStateEditable": True}})
w(f"{dv}/storageconfig.json", {"id": VAULT + "/backupstorageconfig/vaultstorageconfig", "properties": {"storageModelType": "LocallyRedundant", "storageType": "LocallyRedundant", "storageTypeState": "Locked", "crossRegionRestoreFlag": False}})
w(f"{dv}/policies.json", [{"id": VAULT + "/backupPolicies/DailyPolicy", "name": "DailyPolicy", "type": "Microsoft.RecoveryServices/vaults/backupPolicies", "location": LOC,
                            "properties": {"backupManagementType": "AzureStorage", "workLoadType": "AzureFileShare", "protectedItemsCount": 2, "timeZone": "UTC",
                                           "schedulePolicy": {"schedulePolicyType": "SimpleSchedulePolicy", "scheduleRunFrequency": "Daily", "scheduleRunTimes": ["2026-01-01T02:00:00Z"], "scheduleWeeklyFrequency": 0},
                                           "retentionPolicy": {"retentionPolicyType": "LongTermRetentionPolicy", "dailySchedule": {"retentionTimes": ["2026-01-01T02:00:00Z"], "retentionDuration": {"count": 7, "durationType": "Days"}}}}},
                           {"id": VAULT + "/backupPolicies/DefaultPolicy", "name": "DefaultPolicy", "properties": {"backupManagementType": "AzureIaasVM", "protectedItemsCount": 1, "schedulePolicy": {"schedulePolicyType": "SimpleSchedulePolicy", "scheduleRunFrequency": "Daily"}, "retentionPolicy": {"retentionPolicyType": "LongTermRetentionPolicy", "dailySchedule": {"retentionDuration": {"count": 30, "durationType": "Days"}}}}}])
w(f"{dv}/containers.json", [{"id": VAULT + "/backupFabrics/Azure/protectionContainers/StorageContainer;Storage;rg-contoso-files;stcontosofiles01", "name": "StorageContainer;Storage;rg-contoso-files;stcontosofiles01", "properties": {"containerType": "StorageContainer", "backupManagementType": "AzureStorage", "sourceResourceId": SA1, "protectedItemCount": 1, "registrationStatus": "Registered", "healthStatus": "Healthy"}}])
w(f"{dv}/protecteditems.json", [
    {"id": VAULT + "/backupFabrics/Azure/protectionContainers/StorageContainer;Storage;rg-contoso-files;stcontosofiles01/protectedItems/AzureFileShare;dept-shares", "name": "AzureFileShare;dept-shares", "properties": {"friendlyName": "dept-shares", "protectedItemType": "AzureFileShareProtectedItem", "backupManagementType": "AzureStorage", "workloadType": "AzureFileShare", "containerName": "StorageContainer;Storage;rg-contoso-files;stcontosofiles01", "sourceResourceId": SA1, "policyId": VAULT + "/backupPolicies/DailyPolicy", "policyName": "DailyPolicy", "lastBackupStatus": "Healthy", "lastBackupTime": "2026-09-03T02:05:00Z", "protectionStatus": "Healthy", "protectionState": "Protected", "extendedInfo": {"oldestRecoveryPoint": "2026-08-27T02:05:00Z", "recoveryPointCount": 7, "policyState": "Consistent"}, "isScheduledForDeferredDelete": False}},
    {"id": VAULT + "/backupFabrics/Azure/protectionContainers/StorageContainer;Storage;rg-contoso-files;stcontosobackup02/protectedItems/AzureFileShare;gis", "name": "AzureFileShare;gis", "properties": {"friendlyName": "gis", "protectedItemType": "AzureFileShareProtectedItem", "backupManagementType": "AzureStorage", "workloadType": "AzureFileShare", "containerName": "StorageContainer;Storage;rg-contoso-files;stcontosobackup02", "sourceResourceId": SA2, "policyId": VAULT + "/backupPolicies/DailyPolicy", "policyName": "DailyPolicy", "lastBackupStatus": "Unhealthy", "lastBackupTime": "2026-08-30T02:05:00Z", "protectionStatus": "Unhealthy", "protectionState": "ProtectionStopped", "extendedInfo": {"oldestRecoveryPoint": "2026-08-23T02:05:00Z", "recoveryPointCount": 7}, "isScheduledForDeferredDelete": False}},
    {"id": VAULT + "/backupFabrics/Azure/protectionContainers/IaasVMContainer;iaasvmcontainerv2;rg-contoso-files;vm-fs01/protectedItems/VM;iaasvmcontainerv2;rg-contoso-files;vm-fs01", "name": "VM;iaasvmcontainerv2;rg-contoso-files;vm-fs01", "properties": {"friendlyName": "vm-fs01", "protectedItemType": "Microsoft.Compute/virtualMachines", "backupManagementType": "AzureIaasVM", "workloadType": "VM", "policyName": "DefaultPolicy", "protectionState": "Protected", "lastBackupStatus": "Completed"}},
])
w(f"{dv}/jobs.json", [{"id": VAULT + "/backupJobs/j1", "name": "j1", "properties": {"jobType": "AzureStorageJob", "backupManagementType": "AzureStorage", "operation": "Backup", "status": "Failed", "startTime": "2026-09-01T02:00:00Z", "endTime": "2026-09-01T02:01:00Z", "duration": "PT1M", "entityFriendlyName": "gis", "storageAccountName": "stcontosobackup02", "errorDetails": [{"errorCode": 130000, "errorString": "Backup failed: the storage account firewall blocked the request", "recommendations": ["Allow trusted Microsoft services"]}]}},
                       {"id": VAULT + "/backupJobs/j2", "name": "j2", "properties": {"jobType": "AzureStorageJob", "backupManagementType": "AzureStorage", "operation": "Backup", "status": "Completed", "startTime": "2026-09-03T02:00:00Z", "endTime": "2026-09-03T02:05:00Z", "entityFriendlyName": "dept-shares", "storageAccountName": "stcontosofiles01"}}])
w(f"{dv}/resourceguardproxies.json", [])
w(f"{dv}/diagnostics.json", [])
w(f"{dv}/roleassignments.json", [])
w(f"{dv}/locks.json", [])
w("backup/share-coverage.json", [
    {"subscription": SUBNAME, "storageAccount": "stcontosofiles01", "share": "home-drives", "azureFileSync": True, "protected": False, "vault": None, "policy": None, "protectionState": None, "lastBackupStatus": None},
    {"subscription": SUBNAME, "storageAccount": "stcontosofiles01", "share": "dept-shares", "azureFileSync": True, "protected": True, "vault": "rsv-contoso-westus2", "policy": "DailyPolicy", "protectionState": "Protected", "lastBackupStatus": "Healthy"},
    {"subscription": SUBNAME, "storageAccount": "stcontosofiles01", "share": "archive", "azureFileSync": True, "protected": False, "vault": None, "policy": None, "protectionState": None, "lastBackupStatus": None},
    {"subscription": SUBNAME, "storageAccount": "stcontosofiles01", "share": "scans", "azureFileSync": False, "protected": False, "vault": None, "policy": None, "protectionState": None, "lastBackupStatus": None},
    {"subscription": SUBNAME, "storageAccount": "stcontosobackup02", "share": "gis", "azureFileSync": False, "protected": True, "vault": "rsv-contoso-westus2", "policy": "DailyPolicy", "protectionState": "ProtectionStopped", "lastBackupStatus": "Unhealthy"},
])
w(f"backup-dataprotection/{SUBNAME}__bv-blobs/vault.json", {"id": f"{RG}/providers/Microsoft.DataProtection/backupVaults/bv-blobs", "name": "bv-blobs", "location": LOC, "properties": {"storageSettings": [{"datastoreType": "VaultStore", "type": "LocallyRedundant"}]}})
w(f"backup-dataprotection/{SUBNAME}__bv-blobs/policies.json", [])
w(f"backup-dataprotection/{SUBNAME}__bv-blobs/instances.json", [])

# ---- Network / monitor --------------------------------------------------------------------
w("network/privatednszones.json", [])
w("network/privateendpoints.json", [])
w("network/topology.json", [{"id": f"{RG}/providers/Microsoft.Network/virtualNetworks/vnet-hub", "name": "vnet-hub", "type": "microsoft.network/virtualnetworks", "location": LOC, "resourceGroup": "rg-contoso-files", "subscriptionId": SUB, "properties": {"addressSpace": {"addressPrefixes": ["10.100.0.0/16"]}}}])
w("monitor/metricalerts.json", [])

# ---- Server bundle (FS01) -----------------------------------------------------------------
sb = "servers/FS01/FS01-afs-server-20260903-070000"
w(f"{sb}/system.json", {"hostname": "FS01", "domain": "contoso.local", "partOfDomain": True, "osCaption": "Microsoft Windows Server 2022 Standard", "osVersion": "10.0.20348", "osBuild": "20348", "agentProduct": {"DisplayName": "Storage Sync Agent", "DisplayVersion": "19.1.0.0"}, "agentFileVersion": "19.1.0.0", "agentAutoUpdate": {"AutoUpdatePolicy": "InstallLatest"}, "dotNetRelease": 528372, "cluster": None, "collectedAtUtc": "2026-09-03T14:00:00Z", "toolVersion": "1.0.0", "elevated": True})
w(f"{sb}/services.json", {"services": [{"Name": "FileSyncSvc", "DisplayName": "Storage Sync Agent", "Status": "Running", "StartType": "Automatic"}, {"Name": "WSearch", "DisplayName": "Windows Search", "Status": "Running", "StartType": "Automatic"}, {"Name": "W32Time", "Status": "Running"}], "processes": [{"Name": "AzureStorageSyncMonitor", "Id": 1234}, {"Name": "FileSyncSvc", "Id": 1200}], "filterDriversPresent": {"StorageSync": True, "StorageSyncGuard": True}})
w(f"{sb}/volumes.json", {"volumes": [{"drive": "C:", "label": "OS", "fileSystem": "NTFS", "sizeGiB": 120, "freeGiB": 40, "freePercent": 33.3, "bytesPerCluster": 4096}, {"drive": "D:", "label": "Home", "fileSystem": "NTFS", "sizeGiB": 2048, "freeGiB": 164, "freePercent": 8.0, "bytesPerCluster": 4096}, {"drive": "E:", "label": "Dept", "fileSystem": "NTFS", "sizeGiB": 4096, "freeGiB": 1200, "freePercent": 29.3, "bytesPerCluster": 65536}],
                          "dedup": [{"Volume": "D:", "Enabled": True, "MinimumFileAgeDays": 3, "SavedSpace": 100000000, "OptimizedFilesCount": 5000, "UsageType": "Default"}],
                          "features": [{"Name": "FS-DFS-Namespace", "Installed": True}, {"Name": "FS-DFS-Replication", "Installed": False}, {"Name": "FS-Data-Deduplication", "Installed": True}], "windowsSearchScopes": [{"URL": "file:///D:/Home/", "Include": 1}]})
w(f"{sb}/programs.json", {"backupOrAvProducts": [{"DisplayName": "Veeam Agent for Microsoft Windows", "DisplayVersion": "6.1", "Publisher": "Veeam"}], "defender": {"realTime": True, "amRunning": True, "exclusionPaths": []}, "allPrograms": []})
w(f"{sb}/network.json", {"ipConfiguration": [], "dnsTests": []})
w(f"{sb}/smbshares.json", [{"Name": "Home$", "Path": "D:\\Home", "ScopeName": "*"}, {"Name": "Dept", "Path": "E:\\Dept", "ScopeName": "*"}])
w(f"{sb}/registry-storagesync.json", [])
w(f"{sb}/events-telemetry.json", [{"time": "2026-09-03T13:00:00Z", "id": 9121, "level": "Warning", "message": "Per-item errors: PersistentCount: 12 TransientCount: 0"}])
w(f"{sb}/events-operational.json", [])
w(f"{sb}/sync-session-digest.json", [{"time": "2026-09-03T13:00:00Z", "syncGroup": "sg-dept", "direction": "Upload", "hresult": "-2147023436", "perItemErrorCount": 12}, {"time": "2026-09-03T12:00:00Z", "syncGroup": "sg-dept", "direction": "Upload", "hresult": "-2147023436", "perItemErrorCount": 12}, {"time": "2026-09-03T11:00:00Z", "syncGroup": "sg-dept", "direction": "Upload", "hresult": "-2147023436", "perItemErrorCount": 12}, {"time": "2026-09-03T14:00:00Z", "syncGroup": "sg-home", "direction": "Upload", "hresult": "0", "perItemErrorCount": 0}])
w(f"{sb}/selfservicerestore.json", [{"drive": "D:", "result": "SelfServiceRestore : False"}, {"drive": "E:", "result": "SelfServiceRestore : True"}])
w(f"{sb}/errors.json", [])
for name, text in [("w32tm.txt", "Leap Indicator: 0(no warning)\nStratum: 4\nPhase Offset: 0.0123456s\nSource: dc01.contoso.local\n"), ("winhttp-proxy.txt", "Direct access (no proxy server).\n"), ("debug-diagnose.txt", "Checking server time... OK\nChecking server certificate... Error: server certificate expires in 12 days\n"), ("debug-network.txt", "Testing connectivity to management endpoint... Success\n"), ("debug-filesyncerrors.txt", "12 files failed to sync\n"), ("fltmc.txt", "StorageSyncGuard\nStorageSync\n")]:
    p = os.path.join(ROOT, sb, name); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w", encoding="utf-8", newline="\n").write(text)

# ---- Root files ---------------------------------------------------------------------------
w("inventory.json", {"storageSyncServices": [{"id": SSS, "name": "sss-contoso-files", "subscription": SUB, "location": LOC}], "storageAccounts": [{"id": SA1, "name": "stcontosofiles01", "referencedByAzureFileSync": True}, {"id": SA2, "name": "stcontosobackup02", "referencedByAzureFileSync": False}], "recoveryServicesVaults": [{"id": VAULT, "name": "rsv-contoso-westus2"}], "dataProtectionVaults": [], "privateDnsZones": [], "privateEndpoints": []})
w("errors.json", [])
w("manifest.json", {"tool": "Export-AzFileSyncEnvironment.ps1", "toolVersion": "1.0.0", "schema": "luca.afs-export/1", "exportedAtUtc": EXPORTED, "exportedBy": "assessor@contoso.example", "tenantId": "22222222-2222-4222-8222-222222222222", "cloud": "AzureCloud",
                    "subscriptions": [{"id": SUB, "name": SUBNAME}], "jobLookbackDays": 30, "metricsLookbackDays": 7, "metricsSkipped": False,
                    "counts": {"storageSyncServices": 1, "syncGroups": 3, "cloudEndpoints": 3, "serverEndpoints": 4, "registeredServers": 3, "storageAccounts": 2, "fileShares": 5, "recoveryServicesVaults": 1, "backupPolicies": 2, "protectedItems": 3, "backupJobs": 2, "dataProtectionVaults": 1, "privateDnsZones": 0, "privateEndpoints": 0}, "errorCount": 0, "files": []})
open(os.path.join(ROOT, "summary.md"), "w", encoding="utf-8", newline="\n").write("# synthetic export (fixture)\n\nGenerated by fixtures/make-fixture.py - see the test expectations in tests/run-tests.ps1.\n")
print("fixture written to", ROOT)
