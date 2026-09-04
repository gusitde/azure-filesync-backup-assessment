#Requires -Version 5.1
<#
.SYNOPSIS
  Assess an Azure File Sync + Azure Backup export (from Export-AzFileSyncEnvironment.ps1,
  optionally with per-server bundles from Get-AfsServerDiagnostics.ps1) against
  Microsoft-documented best practice, and write findings + a recommendation roadmap.

.DESCRIPTION
  Deterministic first pass: ~60 rules over sync health, agents, cloud tiering, storage
  account security, data durability, Azure Backup (vault security, policies, coverage,
  jobs), private networking, monitoring, operational hygiene and (when bundles are
  present) the registered servers themselves. Every finding carries the evidence that
  triggered it, the recommendation and the Microsoft Learn reference, so an analyst can
  verify it and turn it into the customer-facing recommendation deck.

  Reads only. Writes assessment.md + findings.json next to the export (or -OutputPath).

.PARAMETER ExportPath
  The export folder or the .zip produced by Export-AzFileSyncEnvironment.ps1.

.PARAMETER OutputPath
  Where to write assessment.md / findings.json. Default: the export folder.

.PARAMETER CustomerName
  Name printed in the report header.

.PARAMETER LatestAgentMajor
  Latest Azure File Sync agent major version to compare against (default 20; check
  https://learn.microsoft.com/azure/storage/file-sync/file-sync-release-notes).

.PARAMETER ListRules
  Print the rule catalog (markdown) and exit.

.PARAMETER IncludeCatalog
  Append the rule catalog to assessment.md.

.PARAMETER PrivateTrafficRequired
  The customer requires File Sync traffic to stay on private connectivity (ExpressRoute /
  VPN + Private Link). Escalates public-endpoint findings and adds the NET-05..NET-11
  target-state checks.

.PARAMETER PassThru
  Also return the findings as objects.

.EXAMPLE
  .\Assess-AzFileSyncExport.ps1 -ExportPath .\afs-export-20260903-090000.zip -CustomerName "{customer}"

.NOTES
  Luca Express - azure-filesync-backup-assessment. Version 1.0.0.
#>
[CmdletBinding()]
param(
  [string]$ExportPath,
  [string]$OutputPath,
  [string]$CustomerName = 'Customer',
  [int]$LatestAgentMajor = 20,
  [switch]$ListRules,
  [switch]$IncludeCatalog,
  [switch]$PrivateTrafficRequired,
  [switch]$PassThru
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'

# =========================================================================================
# RULE CATALOG
# =========================================================================================
$L = 'https://learn.microsoft.com/'
$Rules = @(
  # -- Azure File Sync: sync health + topology ------------------------------------------
  @{ Id = 'AFS-01'; Area = 'Sync health'; Severity = 'High'; Title = 'Server endpoint is not healthy'; Check = 'serverEndpoint.syncStatus.combinedHealth is not Healthy (upload/download health Error)'; Recommendation = 'Open the server endpoint in the portal (Errors + troubleshooting), run Debug-StorageSyncServer -FileSyncErrorsReport on the server, fix the per-item or session error, confirm the next 9102 sync session completes with HResult 0.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-sync-errors' }
  @{ Id = 'AFS-02'; Area = 'Sync health'; Severity = 'Medium'; Title = 'Files persistently failing to sync'; Check = 'totalPersistentFilesNotSyncingCount > 0 or last sync per-item error count > 0'; Recommendation = 'Review per-item errors (portal: server endpoint > Errors + troubleshooting; server: FileSyncErrorsReport). Typical causes: unsupported characters, path > 2048, open handles, unsupported file types. Fix at source; sync retries automatically.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-sync-errors#how-do-i-see-if-there-are-specific-files-or-folders-that-are-not-syncing' }
  @{ Id = 'AFS-03'; Area = 'Sync health'; Severity = 'Medium'; Title = 'No successful sync in the last 24 hours'; Check = 'uploadStatus/downloadStatus.lastSyncSuccessTimestamp older than 24 h at export time'; Recommendation = 'Confirm the server is online and FileSyncSvc is running; check the Telemetry log for 9102 sessions; if sessions run but never finish, look for a large initial upload/download or throttling.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-monitoring' }
  @{ Id = 'AFS-04'; Area = 'Registered servers'; Severity = 'High'; Title = 'Registered server appears offline'; Check = 'registeredServer.lastHeartBeat older than 1 h at export time'; Recommendation = 'On the server verify the Storage Sync Agent service and the AzureStorageSyncMonitor.exe process are running and that the server reaches *.afs.azure.com / management endpoints over 443 (Debug-StorageSyncServer -TestNetworkConnectivity). Decommission servers that no longer exist (unregister) so alerts stay meaningful.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-sync-group-management#server-endpoint-noactivity' }
  @{ Id = 'AFS-05'; Area = 'Registered servers'; Severity = 'High'; Title = 'Agent expired, blocked or expiring within 90 days'; Check = 'agentVersionStatus in Expired/Blocked, or agentVersionExpirationDate within 90 days'; Recommendation = 'Update the Azure File Sync agent (Microsoft Update, AfsUpdater.exe or the download center) and enable automatic agent updates (InstallLatest) with a maintenance window. An expired agent stops syncing.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#azure-file-sync-agent-update-policy' }
  @{ Id = 'AFS-06'; Area = 'Registered servers'; Severity = 'Medium'; Title = 'Agent is not on the latest major version'; Check = 'agentVersion major < LatestAgentMajor parameter'; Recommendation = 'Plan the agent upgrade in a maintenance window. Managed-identity authentication requires v20+. Check the release notes for the supported-version dates.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-release-notes' }
  @{ Id = 'AFS-07'; Area = 'Registered servers'; Severity = 'High'; Title = 'Registered server OS is not supported'; Check = 'serverOSVersion is not Windows Server 2016/2019/2022/2025 (kernel 10.0.x)'; Recommendation = 'Azure File Sync supports Windows Server 2016 and later only. Migrate the server endpoint to a supported server (install the agent on the new server, add it to the sync group, then remove the old endpoint).'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#operating-system-requirements' }
  @{ Id = 'AFS-08'; Area = 'Cloud endpoint'; Severity = 'Low'; Title = 'Cloud change enumeration is stale'; Check = 'changeEnumerationStatus.lastCompletedEnumeration older than 48 h or absent'; Recommendation = 'Changes made directly in the Azure file share (portal, REST, Backup restore) are detected by a 24 h enumeration job. If users or tools write to the share directly, run Invoke-AzStorageSyncChangeDetection after bulk changes and keep the share as the sync hub rather than a direct target.'; Ref = "$L" + 'powershell/module/az.storagesync/invoke-azstoragesyncchangedetection' }
  @{ Id = 'AFS-09'; Area = 'Topology'; Severity = 'Medium'; Title = 'Server endpoint on the system volume'; Check = 'serverLocalPath starts with C:\'; Recommendation = 'Move the server endpoint to a data volume. Cloud tiering is not supported on the system volume and OS/pagefile growth competes with the volume free-space policy.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#considerations-for-windows-file-servers' }
  @{ Id = 'AFS-10'; Area = 'Topology'; Severity = 'High'; Title = 'Nested or overlapping server endpoints on the same server'; Check = 'one serverLocalPath is a prefix of another on the same serverResourceId'; Recommendation = 'Nested server endpoints are unsupported. Restructure so each server endpoint is a distinct, non-overlapping path (volume sync: sync the common root once).'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#planning-for-balanced-sync-topologies' }
  @{ Id = 'AFS-11'; Area = 'Networking'; Severity = 'High'; Title = 'Storage Sync Service public endpoint disabled without an approved private endpoint'; Check = 'incomingTrafficPolicy = AllowVirtualNetworksOnly and no Approved privateEndpointConnections'; Recommendation = 'Sync cannot work: create and approve a private endpoint for the Storage Sync Service (privatelink.afs.azure.net DNS) before disabling the public endpoint, or set incomingTrafficPolicy back to AllowAllTraffic.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#disable-access-to-the-storage-sync-service-public-endpoint' }
  @{ Id = 'AFS-12'; Area = 'Identity'; Severity = 'Medium'; Title = 'Storage Sync Service authenticates with the storage account key (managed identity off)'; Check = 'storageSyncService.useIdentity is not true'; Recommendation = 'Move to system-assigned managed identities: agent v20+, Azure Arc on on-premises servers, then Set-AzStorageSyncServiceIdentity (grants Storage Account Contributor + Storage File Data Privileged Contributor). Afterwards shared-key access can be disabled on the storage account (mind Azure Backup for Azure Files, which still requires key access).'; Ref = "$L" + 'azure/storage/file-sync/file-sync-managed-identities' }
  @{ Id = 'AFS-13'; Area = 'Scope'; Severity = 'High'; Title = 'Cloud endpoint storage account is outside the export'; Check = 'cloudEndpoint.storageAccountResourceId not found among exported storage accounts'; Recommendation = 'The share behind this sync group was not assessed. Re-run the export including that subscription, or grant Reader on that storage account.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning' }
  @{ Id = 'AFS-14'; Area = 'Networking'; Severity = 'High'; Title = 'Storage account firewall blocks the Storage Sync Service'; Check = 'networkAcls.defaultAction = Deny, bypass lacks AzureServices, no resourceAccessRules for Microsoft.StorageSync'; Recommendation = 'Enable "Allow Azure services on the trusted services list" (bypass AzureServices) or add a resource-instance rule for the Storage Sync Service; keep IP/VNet rules for the servers. Without it cloud endpoint operations and change enumeration fail.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#restrict-access-to-the-storage-account-public-endpoint' }
  @{ Id = 'AFS-15'; Area = 'Registered servers'; Severity = 'Info'; Title = 'Clustered registered server'; Check = 'registeredServer.clusterName present'; Recommendation = 'Clustered servers are excluded from automatic agent updates (InstallLatest) - schedule manual agent updates per node.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#automatic-management-of-the-agent-lifecycle' }
  @{ Id = 'AFS-16'; Area = 'Topology'; Severity = 'Medium'; Title = 'Storage Sync Service and storage account are in different regions'; Check = 'storageSyncService.location differs from cloud endpoint storage account location'; Recommendation = 'Keep the Storage Sync Service in the same region as its storage accounts (latency, egress, DR alignment). Moving requires recreating the sync group; plan during a migration window.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#azure-file-sync-region-availability' }
  @{ Id = 'AFS-17'; Area = 'Topology'; Severity = 'Info'; Title = 'Sync group has no server endpoint'; Check = 'sync group with 0 server endpoints'; Recommendation = 'Cloud-only sync group: either add the intended server endpoint or remove the group to keep the topology clean.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-deployment-guide' }
  @{ Id = 'AFS-18'; Area = 'Hygiene'; Severity = 'Low'; Title = 'No delete lock on the Storage Sync Service'; Check = 'no CanNotDelete lock at the sync service'; Recommendation = 'Add a CanNotDelete lock. Deleting the service deletes all sync groups and server registrations.'; Ref = "$L" + 'azure/azure-resource-manager/management/lock-resources' }
  @{ Id = 'AFS-19'; Area = 'Identity'; Severity = 'Info'; Title = 'Registered server still on certificate (shared key) authentication'; Check = 'service useIdentity = true but server activeAuthType != ManagedIdentity'; Recommendation = 'Give the server a system-assigned managed identity (Arc-enabled server or Azure VM) and re-run Set-AzStorageSyncServiceIdentity for it.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-managed-identities#after-configuration-next-steps-and-troubleshooting' }
  # -- Cloud tiering ------------------------------------------------------------------
  @{ Id = 'TIER-01'; Area = 'Cloud tiering'; Severity = 'Info'; Title = 'Cloud tiering disabled (full copy on the server)'; Check = 'serverEndpoint.cloudTiering = off'; Recommendation = 'Acceptable when the server must hold the full data set (and it is the only topology where server-side backup of the endpoint is supported). Otherwise enable tiering with a volume free-space policy sized for the hot set to reduce local storage.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-cloud-tiering-overview' }
  @{ Id = 'TIER-02'; Area = 'Cloud tiering'; Severity = 'Medium'; Title = 'Cloud tiering is not healthy'; Check = 'cloudTieringStatus.health != Healthy or lastCloudTieringResult != 0'; Recommendation = 'Check Telemetry events 9003 (tiering errors) / 9016 / 9029 on the server; common causes: files in use, unsupported attributes, low free space, antivirus holding handles.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-cloud-tiering' }
  @{ Id = 'TIER-03'; Area = 'Cloud tiering'; Severity = 'High'; Title = 'Server endpoint is in low disk space mode'; Check = 'cloudTieringStatus.lowDiskMode.state = Enabled'; Recommendation = 'Free space on the volume (or lower the volume free-space policy / extend the disk). In low disk mode recalls and tiering behave defensively and users see slow access.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-monitoring#create-an-alert-if-a-server-endpoint-enters-low-disk-space-mode' }
  @{ Id = 'TIER-04'; Area = 'Cloud tiering'; Severity = 'Low'; Title = 'Volume free-space policy is very low'; Check = 'volumeFreeSpacePercent < 10'; Recommendation = 'Keep at least 10-20 % free: NTFS, the sync metadata database and the heat store need headroom; below that tiering churns and recalls slow down.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#free-space-on-your-local-disk' }
  @{ Id = 'TIER-05'; Area = 'Cloud tiering'; Severity = 'Low'; Title = 'Low cloud-tiering cache hit ratio'; Check = 'cachePerformance.cacheHitRatio < 0.8 with tiering on'; Recommendation = 'The local cache is too small for the working set or the date policy is too aggressive: raise local capacity / lower the free-space policy or increase tierFilesOlderThanDays; watch recall egress.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-monitor-cloud-tiering' }
  @{ Id = 'TIER-06'; Area = 'Cloud tiering'; Severity = 'Medium'; Title = 'Large daily recall volume'; Check = 'StorageSyncRecallTotalSizeBytes > 500 GiB in a day (metrics)'; Recommendation = 'Something reads tiered files in bulk: antivirus full scans, backup agents, indexers, data-classification tools. Exclude the FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS attribute in those products or move them off the server endpoint; egress costs money.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#antivirus' }
  # -- Storage account security ---------------------------------------------------------
  @{ Id = 'SEC-01'; Area = 'Storage security'; Severity = 'High'; Title = 'Secure transfer (HTTPS only) is disabled'; Check = 'supportsHttpsTrafficOnly = false'; Recommendation = 'Enable "Secure transfer required". Azure File Sync always uses encrypted channels; the switch protects direct SMB/REST clients.'; Ref = "$L" + 'azure/storage/common/storage-require-secure-transfer' }
  @{ Id = 'SEC-02'; Area = 'Storage security'; Severity = 'High'; Title = 'Minimum TLS version below 1.2'; Check = 'minimumTlsVersion != TLS1_2/TLS1_3'; Recommendation = 'Set minimum TLS to 1.2. Check the storage account Transactions metric by TLS version first to catch legacy clients.'; Ref = "$L" + 'azure/storage/common/transport-layer-security-configure-minimum-version' }
  @{ Id = 'SEC-03'; Area = 'Storage security'; Severity = 'Medium'; Title = 'Storage account public endpoint open to all networks'; Check = 'publicNetworkAccess != Disabled and networkAcls.defaultAction = Allow'; Recommendation = 'Set the firewall default to Deny, enable "Allow Azure services on the trusted services list" (required by Azure File Sync and Azure Backup), then allow only the registered servers (public IPs or VNet service endpoints) and admin networks, or add a private endpoint for the file service. Test sync after the change.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#restrict-access-to-the-storage-account-public-endpoint' }
  @{ Id = 'SEC-04'; Area = 'Storage security'; Severity = 'Info'; Title = 'Shared key access is allowed'; Check = 'allowSharedKeyAccess is true/absent'; Recommendation = 'Required today: Azure File Sync without managed identity authenticates with the account key, and Azure Backup for Azure Files requires "Allow storage account key access". Keep it, protect the keys (no key use in scripts, rotation policy, Defender), and revisit after the managed-identity migration and when Backup drops the requirement.'; Ref = "$L" + 'azure/backup/azure-file-share-support-matrix#supported-storage-accounts' }
  @{ Id = 'SEC-05'; Area = 'Storage security'; Severity = 'Medium'; Title = 'Public network access fully disabled on a File Sync storage account'; Check = 'publicNetworkAccess = Disabled on an account referenced by a cloud endpoint'; Recommendation = 'Verify sync and cloud change enumeration still work: Microsoft guidance for File Sync is default action Deny + trusted services bypass (+ private endpoint for servers), not disabling public network access outright. If health is fine, document the exception; if not, revert to Deny + trusted services.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#grant-access-to-trusted-azure-services-and-disable-access-to-the-storage-account-public-endpoint' }
  @{ Id = 'SEC-06'; Area = 'Storage security'; Severity = 'Low'; Title = 'Account keys are old or have no expiration policy'; Check = 'keyCreationTime older than 365 days or keyPolicy.keyExpirationPeriodInDays not set'; Recommendation = 'Set a key expiration policy (for example 180 days) and rotate keys in a maintenance window. Azure File Sync re-reads the key from the account and Azure Backup uses the trusted service path, so rotation is non-disruptive.'; Ref = "$L" + 'azure/storage/common/storage-account-keys-manage#create-a-key-expiration-policy' }
  @{ Id = 'SEC-07'; Area = 'Storage security'; Severity = 'Low'; Title = 'No identity-based (Kerberos) authentication on the file share'; Check = 'azureFilesIdentityBasedAuthentication.directoryServiceOptions = None'; Recommendation = 'Not required for Azure File Sync (users go through the Windows Server, which enforces NTFS ACLs). If anyone mounts the Azure file share directly, join the storage account to {customer} AD DS (or Entra Kerberos) so on-premises ACLs are enforced in the cloud instead of using the account key.'; Ref = "$L" + 'azure/storage/files/storage-files-active-directory-overview' }
  @{ Id = 'SEC-08'; Area = 'Storage security'; Severity = 'Low'; Title = 'SMB security settings at defaults'; Check = 'fileServices.protocolSettings.smb allows SMB 2.1 / NTLMv2 / AES-128-CCM (defaults)'; Recommendation = 'Harden SMB: versions SMB3.0;SMB3.1.1, channel encryption AES-128-GCM;AES-256-GCM, Kerberos ticket encryption AES-256, authentication Kerberos where identity-based auth is on. Azure File Sync uses REST, so sync is unaffected; check direct SMB clients first.'; Ref = "$L" + 'azure/storage/files/files-smb-protocol#smb-security-settings' }
  @{ Id = 'SEC-09'; Area = 'Storage security'; Severity = 'Medium'; Title = 'Microsoft Defender for Storage is not enabled'; Check = 'subscription pricing StorageAccounts = Free and no per-account Defender setting'; Recommendation = 'Enable Defender for Storage (activity monitoring; malware scanning optional) on the subscription or at least on the File Sync / backup storage accounts.'; Ref = "$L" + 'azure/defender-for-cloud/defender-for-storage-introduction' }
  @{ Id = 'SEC-10'; Area = 'Storage security'; Severity = 'Low'; Title = 'No delete lock on a storage account holding synced or backed-up shares'; Check = 'no CanNotDelete lock at the storage account'; Recommendation = 'Add a CanNotDelete lock. Soft delete covers shares, not the account itself.'; Ref = "$L" + 'azure/azure-resource-manager/management/lock-resources' }
  @{ Id = 'SEC-11'; Area = 'Storage security'; Severity = 'Low'; Title = 'Anonymous blob access allowed'; Check = 'allowBlobPublicAccess = true'; Recommendation = 'Set allowBlobPublicAccess to false unless a documented public container exists.'; Ref = "$L" + 'azure/storage/blobs/anonymous-read-access-prevent' }
  @{ Id = 'SEC-12'; Area = 'Storage security'; Severity = 'Low'; Title = 'Cross-tenant object replication allowed'; Check = 'allowCrossTenantReplication = true'; Recommendation = 'Set allowCrossTenantReplication to false (hygiene; not used by Azure Files).'; Ref = "$L" + 'azure/storage/blobs/object-replication-prevent-cross-tenant-policies' }
  @{ Id = 'SEC-13'; Area = 'Storage security'; Severity = 'Low'; Title = 'Privileged roles assigned directly to users on the storage account'; Check = 'Owner / Contributor / Storage Account Contributor assigned to principalType User at account scope'; Recommendation = 'Assign privileged roles to groups (PIM-eligible where possible) and keep standing user assignments to Reader.'; Ref = "$L" + 'azure/role-based-access-control/best-practices' }
  @{ Id = 'SEC-14'; Area = 'Storage security'; Severity = 'Info'; Title = 'Platform-managed encryption keys'; Check = 'encryption.keySource = Microsoft.Storage'; Recommendation = 'Meets the baseline (AES-256 at rest). Customer-managed keys / infrastructure (double) encryption only if {customer} policy or a regulation mandates it.'; Ref = "$L" + 'azure/storage/common/storage-service-encryption' }
  @{ Id = 'SEC-15'; Area = 'Storage security'; Severity = 'Low'; Title = 'SFTP or local users enabled'; Check = 'isSftpEnabled or isLocalUserEnabled = true'; Recommendation = 'Disable unless a documented use case exists.'; Ref = "$L" + 'azure/storage/blobs/secure-file-transfer-protocol-support' }
  # -- Data durability --------------------------------------------------------------------
  @{ Id = 'DATA-01'; Area = 'Durability'; Severity = 'Medium'; Title = 'Locally redundant storage for synced / backed-up shares'; Check = 'sku = Standard_LRS or Premium_LRS on an account with file shares in scope'; Recommendation = 'Use ZRS (zone loss) or GRS/GZRS (region loss) for the authoritative copy of {customer} file data. Note: with Azure File Sync do not initiate a manual geo-failover outside a disaster (open a support case so sync resumes on the secondary).'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#redundancy' }
  @{ Id = 'DATA-02'; Area = 'Durability'; Severity = 'High'; Title = 'File share soft delete disabled or shorter than 14 days'; Check = 'fileServices.shareDeleteRetentionPolicy disabled or days < 14'; Recommendation = 'Enable share soft delete with 14+ days (Azure Backup sets 14 automatically). It is the only protection against an accidental or malicious share deletion, including its snapshots.'; Ref = "$L" + 'azure/storage/files/storage-files-prevent-file-share-deletion' }
  @{ Id = 'DATA-03'; Area = 'Durability'; Severity = 'Medium'; Title = 'File share close to its quota'; Check = 'shareUsageBytes > 80 % of shareQuota (High above 95 %)'; Recommendation = 'Raise the share quota (or enable large file shares / move to provisioned v2). When the share is full, uploads from every server endpoint fail.'; Ref = "$L" + 'azure/storage/files/storage-how-to-create-file-share#expand-existing-file-shares' }
  @{ Id = 'DATA-04'; Area = 'Durability'; Severity = 'Low'; Title = 'Share snapshot count near the 200 limit'; Check = 'more than 150 snapshots on one share'; Recommendation = 'Azure Backup and manual snapshots share the 200-per-share limit; prune manual snapshots and align backup retention.'; Ref = "$L" + 'azure/backup/azure-file-share-support-matrix#retention-limits' }
  @{ Id = 'DATA-05'; Area = 'Durability'; Severity = 'Info'; Title = 'Soft-deleted shares are present'; Check = 'shares with deleted = true'; Recommendation = 'Recover if the deletion was accidental (portal > Undelete) before remainingRetentionDays expires; otherwise nothing to do.'; Ref = "$L" + 'azure/storage/files/storage-files-prevent-file-share-deletion' }
  @{ Id = 'DATA-06'; Area = 'Durability'; Severity = 'Low'; Title = 'Large file shares disabled'; Check = 'largeFileSharesState != Enabled on a StorageV2 account'; Recommendation = 'Enable large file shares (up to 100 TiB, higher IOPS) on the file sync storage account; it cannot be disabled afterwards but has no cost impact.'; Ref = "$L" + 'azure/storage/files/storage-how-to-create-file-share#enable-large-file-shares-on-an-existing-account' }
  @{ Id = 'DATA-07'; Area = 'Durability'; Severity = 'Low'; Title = 'Read-access geo redundancy on a file share account'; Check = 'sku = Standard_RAGRS or Standard_RAGZRS'; Recommendation = 'Azure Files cannot read from the secondary; RA-GRS is billed as GRS with no benefit. Switch to GRS / GZRS.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#redundancy' }
  # -- Azure Backup ---------------------------------------------------------------------
  @{ Id = 'BKP-01'; Area = 'Backup coverage'; Severity = 'High'; Title = 'File share is not protected by Azure Backup'; Check = 'share not found among protected items (workloadType AzureFileShare) in any vault'; Recommendation = 'Configure Azure Backup for the share from a Recovery Services vault in the same region: policy with daily (or 4-hourly) snapshots and vaulted (offsite, immutable) copies, retention per {customer} records schedule. For Azure File Sync cloud endpoints this is the supported backup path (server-side backup of tiered endpoints is unsupported).'; Ref = "$L" + 'azure/backup/backup-azure-files' }
  @{ Id = 'BKP-02'; Area = 'Backup health'; Severity = 'High'; Title = 'Protected share is unhealthy or protection stopped'; Check = 'lastBackupStatus != Healthy or protectionState != Protected'; Recommendation = 'Open the backup item, read the last job error, fix (common: storage account firewall without trusted services, key access disabled, share deleted) and run an on-demand backup.'; Ref = "$L" + 'azure/backup/troubleshoot-azure-files' }
  @{ Id = 'BKP-03'; Area = 'Backup health'; Severity = 'Medium'; Title = 'Backup jobs failed in the lookback window'; Check = 'backupJobs with status Failed'; Recommendation = 'Review the failed jobs (error codes + recommendations are in jobs.json), fix the cause and confirm the next scheduled run.'; Ref = "$L" + 'azure/backup/troubleshoot-azure-files' }
  @{ Id = 'BKP-04'; Area = 'Backup design'; Severity = 'Medium'; Title = 'Snapshot-only backup policy (no vaulted copy)'; Check = 'AzureStorage policy without vaultRetentionPolicy'; Recommendation = 'Snapshots live in the same storage account as the data. Add the vault-standard tier (GA) for an offsite, immutable, cross-region-restorable copy: migrate the existing policy in a supported region or create a new vaulted policy and re-protect the shares.'; Ref = "$L" + 'azure/backup/azure-file-share-backup-overview' }
  @{ Id = 'BKP-05'; Area = 'Backup design'; Severity = 'Low'; Title = 'Retention is short or has no weekly / monthly / yearly points'; Check = 'daily retention < 30 days or no weekly/monthly/yearly schedule'; Recommendation = 'Align retention with {customer} records-retention schedule and the ransomware dwell-time assumption (30-90 days of daily points is common; monthly/yearly for compliance).'; Ref = "$L" + 'azure/backup/azure-file-share-support-matrix#retention-limits' }
  @{ Id = 'BKP-06'; Area = 'Vault security'; Severity = 'High'; Title = 'Vault soft delete is off or not always-on'; Check = 'securitySettings.softDeleteSettings.softDeleteState != Enabled (Medium when Enabled but not AlwaysON)'; Recommendation = 'Enable soft delete and set it to always-on with 14-180 days retention, so deleted backup data survives an attacker with vault rights.'; Ref = "$L" + 'azure/backup/backup-azure-security-feature-cloud' }
  @{ Id = 'BKP-07'; Area = 'Vault security'; Severity = 'Medium'; Title = 'Vault immutability disabled'; Check = 'securitySettings.immutabilitySettings.state != Unlocked/Locked'; Recommendation = 'Enable immutability (Unlocked first, Locked after validation) so recovery points cannot be deleted before retention expires.'; Ref = "$L" + 'azure/backup/backup-azure-immutable-vault-concept' }
  @{ Id = 'BKP-08'; Area = 'Vault security'; Severity = 'Medium'; Title = 'Multi-user authorization (Resource Guard) not configured'; Check = 'no backupResourceGuardProxies and multiUserAuthorization not Enabled'; Recommendation = 'Create a Resource Guard in a separate subscription/tenant owned by a second admin and enable MUA on the vault for critical operations (disable soft delete, delete backup, modify policy).'; Ref = "$L" + 'azure/backup/multi-user-authorization-concept' }
  @{ Id = 'BKP-09'; Area = 'Vault design'; Severity = 'Medium'; Title = 'Vault storage is locally redundant'; Check = 'redundancySettings.standardTierStorageRedundancy = LocallyRedundant'; Recommendation = 'Use GeoRedundant with Cross Region Restore for vaulted copies. Redundancy is fixed once the first item is protected, so decide before onboarding vaulted backups (new vault if needed).'; Ref = "$L" + 'azure/backup/backup-create-recovery-services-vault#set-storage-redundancy' }
  @{ Id = 'BKP-10'; Area = 'Vault design'; Severity = 'Low'; Title = 'Cross Region Restore disabled on a geo-redundant vault'; Check = 'redundancySettings.crossRegionRestore != Enabled while storage is GeoRedundant'; Recommendation = 'Enable Cross Region Restore so vaulted Azure Files copies can be restored in the paired region during a regional outage.'; Ref = "$L" + 'azure/backup/backup-create-recovery-services-vault#set-cross-region-restore' }
  @{ Id = 'BKP-11'; Area = 'Monitoring'; Severity = 'Medium'; Title = 'Azure Monitor alerts for backup job failures are off'; Check = 'monitoringSettings.azureMonitorAlertSettings.alertsForAllJobFailures != Enabled'; Recommendation = 'Enable built-in Azure Monitor alerts for all job failures and route them to an action group (email/Teams) the storage team reads.'; Ref = "$L" + 'azure/backup/backup-azure-monitoring-built-in-monitor' }
  @{ Id = 'BKP-12'; Area = 'Monitoring'; Severity = 'Low'; Title = 'No diagnostic settings on the vault'; Check = 'no diagnosticSettings on the Recovery Services vault'; Recommendation = 'Send AzureBackupReport / CoreAzureBackup / AddonAzureBackupJobs logs to a Log Analytics workspace and use Backup reports for RPO/compliance evidence.'; Ref = "$L" + 'azure/backup/configure-reports' }
  @{ Id = 'BKP-13'; Area = 'Backup design'; Severity = 'Info'; Title = 'Once-daily backup schedule'; Check = 'AzureStorage policy scheduleRunFrequency = Daily'; Recommendation = 'Confirm the RPO with the business: Azure Files supports hourly snapshots (every 4/6/8/12 h); for actively edited File Sync shares 4-hourly snapshots with 30-day retention plus daily vaulted copies is a strong default.'; Ref = "$L" + 'azure/backup/backup-azure-files#create-a-backup-policy' }
  @{ Id = 'BKP-14'; Area = 'Backup coverage'; Severity = 'Medium'; Title = 'No Recovery Services vault in the region of unprotected shares'; Check = 'unprotected shares in region R and no vault in R'; Recommendation = 'Azure Files backup requires the vault in the same region as the storage account: create a vault there (GRS + CRR, soft delete always-on, immutability, MUA) before configuring backup.'; Ref = "$L" + 'azure/backup/backup-azure-files#prerequisites' }
  @{ Id = 'BKP-15'; Area = 'Backup health'; Severity = 'Info'; Title = 'Backup items in soft-deleted state'; Check = 'protected item isScheduledForDeferredDelete = true'; Recommendation = 'Undelete (resume protection) if unintended, otherwise they purge after the soft-delete retention.'; Ref = "$L" + 'azure/backup/backup-azure-security-feature-cloud' }
  @{ Id = 'BKP-16'; Area = 'Vault security'; Severity = 'Low'; Title = 'No delete lock on the vault'; Check = 'no CanNotDelete lock at the vault'; Recommendation = 'Add a CanNotDelete lock to the Recovery Services vault.'; Ref = "$L" + 'azure/azure-resource-manager/management/lock-resources' }
  @{ Id = 'BKP-17'; Area = 'Backup coverage'; Severity = 'Info'; Title = 'Data Protection (Backup) vaults present'; Check = 'Microsoft.DataProtection backupVaults in scope'; Recommendation = 'Blob / disk / database backups live here; review their policies separately when extending "backup for all data in Azure".'; Ref = "$L" + 'azure/backup/backup-vault-overview' }
  @{ Id = 'BKP-18'; Area = 'Backup health'; Severity = 'High'; Title = 'Shared key access disabled on an account with backed-up shares'; Check = 'allowSharedKeyAccess = false and the account has protected shares'; Recommendation = 'Azure Backup for Azure Files requires "Allow storage account key access" enabled; backups and restores will fail until it is re-enabled.'; Ref = "$L" + 'azure/backup/azure-file-share-support-matrix#supported-storage-accounts' }
  @{ Id = 'BKP-19'; Area = 'Backup coverage'; Severity = 'Info'; Title = 'Non-file workloads protected in the vault'; Check = 'protected items of other workload types (VM, SQL, MARS)'; Recommendation = 'Inventory only - these are outside the Azure Files scope but count toward "backup for all data in Azure".'; Ref = "$L" + 'azure/backup/backup-overview' }
  # -- Private networking ------------------------------------------------------------------
  @{ Id = 'NET-01'; Area = 'Networking'; Severity = 'Info'; Title = 'Public endpoints in use (no private endpoints for Files / File Sync)'; Check = 'no privatelink.file / privatelink.afs zone and no relevant private endpoint'; Recommendation = 'Acceptable: the agent uses HTTPS/443 with Microsoft routing. Move to private endpoints (storage account "file" + Storage Sync Service) only if {customer} policy requires private routing over VPN/ExpressRoute; then integrate DNS (privatelink zones or conditional forwarders on the Infoblox grid).'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-overview' }
  @{ Id = 'NET-02'; Area = 'Networking'; Severity = 'Medium'; Title = 'Private endpoint without working private DNS'; Check = 'relevant private endpoint present but no privatelink zone with a VNet link and A record for it'; Recommendation = 'Add the privatelink.file.core.windows.net / privatelink.afs.azure.net zone, link it to the VNets, and add a DNS zone group to the private endpoint (or conditional forwarders from on-premises DNS). Otherwise clients resolve the public IP and the firewall drops them.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#create-the-private-endpoints' }
  @{ Id = 'NET-03'; Area = 'Networking'; Severity = 'Medium'; Title = 'Private endpoint connection not approved'; Check = 'privateLinkServiceConnectionState.status != Approved'; Recommendation = 'Approve (or remove) the pending private endpoint connection on the target resource.'; Ref = "$L" + 'azure/private-link/manage-private-endpoint' }
  @{ Id = 'NET-04'; Area = 'Networking'; Severity = 'Low'; Title = 'Private endpoint without a private DNS zone group'; Check = 'no privateDnsZoneGroups on the private endpoint'; Recommendation = 'Add a DNS zone group so the A record is managed automatically when the endpoint IP changes.'; Ref = "$L" + 'azure/private-link/private-endpoint-dns-integration' }
  @{ Id = 'NET-05'; Area = 'Networking'; Severity = 'High'; Title = 'Storage Sync Service has no private endpoint (private routing required)'; Check = 'PrivateTrafficRequired and no Approved privateEndpointConnections on the Storage Sync Service'; Recommendation = 'Create a private endpoint for the Storage Sync Service (sub-resource afs) in the hub or a shared-services spoke reachable over ExpressRoute private peering, link privatelink.afs.azure.net to the VNets, publish it to on-premises DNS (Infoblox conditional forwarder -> Azure DNS Private Resolver inbound endpoint), verify the servers resolve the four *.afs.azure.net names to the private IPs, then set incomingTrafficPolicy = AllowVirtualNetworksOnly.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#create-the-storage-sync-service-private-endpoint' }
  @{ Id = 'NET-06'; Area = 'Networking'; Severity = 'High'; Title = 'File Sync storage account has no file private endpoint (private routing required)'; Check = 'PrivateTrafficRequired and no privateEndpointConnections on a storage account referenced by a cloud endpoint'; Recommendation = 'Create a private endpoint for the storage account (sub-resource file) in the same hub/spoke, link privatelink.file.core.windows.net, forward it from Infoblox, then set the storage firewall to Deny with "Allow Azure services on the trusted services list" so the Storage Sync Service and Azure Backup keep working while servers use the ExpressRoute path.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#create-the-storage-account-private-endpoint' }
  @{ Id = 'NET-07'; Area = 'Networking'; Severity = 'Medium'; Title = 'Storage Sync Service public endpoint still enabled although a private endpoint exists'; Check = 'PrivateTrafficRequired, approved private endpoint present, incomingTrafficPolicy = AllowAllTraffic'; Recommendation = 'After confirming every registered server resolves the service privately (Debug-StorageSyncServer -TestNetworkConnectivity), set incomingTrafficPolicy = AllowVirtualNetworksOnly so sync traffic cannot fall back to the internet.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#disable-access-to-the-storage-sync-service-public-endpoint' }
  @{ Id = 'NET-08'; Area = 'Networking'; Severity = 'Medium'; Title = 'Storage account public endpoint open although a private endpoint exists'; Check = 'PrivateTrafficRequired, private endpoint present, networkAcls.defaultAction = Allow'; Recommendation = 'Set the storage firewall default action to Deny and keep "Allow Azure services on the trusted services list" enabled (Azure File Sync + Azure Backup). Add IP rules only for admin networks that must use the public endpoint.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-networking-endpoints#grant-access-to-trusted-azure-services-and-disable-access-to-the-storage-account-public-endpoint' }
  @{ Id = 'NET-09'; Area = 'Networking'; Severity = 'Info'; Title = 'Azure Backup for Azure Files does not traverse the customer network'; Check = 'PrivateTrafficRequired and Azure Files backup in scope'; Recommendation = 'Backup snapshots and vault transfers are Azure-internal (Backup service -> storage account over the trusted-services path); a private endpoint on the vault does not apply to Azure Files. Nothing needs to be routed over ExpressRoute for backup; restores land in the Azure file share and reach the servers through File Sync over the private path. Only the management plane (portal / PowerShell) is client-side.'; Ref = "$L" + 'azure/backup/azure-file-share-support-matrix#supported-storage-accounts' }
  @{ Id = 'NET-10'; Area = 'Networking'; Severity = 'Medium'; Title = 'No ExpressRoute / VPN gateway found for the private path'; Check = 'PrivateTrafficRequired and topology has no ExpressRoute circuit, ExpressRoute/VPN gateway or connection'; Recommendation = 'Private endpoints are only reachable from on-premises through ExpressRoute private peering or a VPN gateway in the hub VNet that is peered (gateway transit) to the private endpoint VNet. Provision or document the circuit, gateway and connection before cutting over.'; Ref = "$L" + 'azure/private-link/private-endpoint-overview#private-endpoint-properties' }
  @{ Id = 'NET-11'; Area = 'Networking'; Severity = 'Medium'; Title = 'No Azure DNS Private Resolver for on-premises name resolution'; Check = 'PrivateTrafficRequired and topology has no dnsResolvers'; Recommendation = 'Deploy Azure DNS Private Resolver (inbound endpoint in the hub) and create conditional forwarders on the on-premises DNS (Infoblox) for privatelink.file.core.windows.net and privatelink.afs.azure.net (or file.core.windows.net / afs.azure.net) pointing to the inbound endpoint IP, so the registered servers resolve private endpoint IPs.'; Ref = "$L" + 'azure/dns/private-resolver-hybrid-dns' }
  # -- Monitoring ---------------------------------------------------------------------------
  @{ Id = 'MON-01'; Area = 'Monitoring'; Severity = 'Medium'; Title = 'No alert rules on the Storage Sync Service'; Check = 'no metricAlerts scoped to the Storage Sync Service'; Recommendation = 'Create the recommended alerts (portal > Storage Sync Service > Alerts > "Set up recommended alerts"): Sync session result, Files not syncing, Server online status, Low disk space mode, Recall size > 500 GiB/day, Agent version expiration - routed to an action group.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-monitoring#set-up-recommended-alerts' }
  @{ Id = 'MON-02'; Area = 'Monitoring'; Severity = 'Low'; Title = 'No availability alert on the File Sync storage account'; Check = 'no metricAlerts scoped to a storage account referenced by a cloud endpoint'; Recommendation = 'Add an Availability < 100 % (file service) alert and a Used capacity / quota alert on the storage account.'; Ref = "$L" + 'azure/storage/files/storage-files-monitoring' }
  @{ Id = 'MON-03'; Area = 'Monitoring'; Severity = 'Low'; Title = 'File service logs not sent to Log Analytics'; Check = 'no diagnosticSettings on fileServices/default for a File Sync storage account'; Recommendation = 'Enable StorageRead/StorageWrite/StorageDelete logs to a Log Analytics workspace (audit who deleted what, evidence for incidents).'; Ref = "$L" + 'azure/storage/files/storage-files-monitoring#collect-data-with-azure-monitor' }
  # -- Operations ------------------------------------------------------------------------------
  @{ Id = 'OPS-01'; Area = 'Hygiene'; Severity = 'Low'; Title = 'Resource has no owner / environment tags'; Check = 'tags lack owner and environment (any case)'; Recommendation = 'Tag the Storage Sync Service, storage accounts and vaults (owner, environment, costCenter, dataClassification) so alerts and cost reports route correctly.'; Ref = "$L" + 'azure/azure-resource-manager/management/tag-resources' }
  @{ Id = 'OPS-02'; Area = 'Scope'; Severity = 'Info'; Title = 'Export had failed calls (assessment gaps)'; Check = 'errors.json not empty'; Recommendation = 'Re-run the export with Reader on the listed resources, or accept the gap and note it in the report.'; Ref = "$L" + 'azure/role-based-access-control/built-in-roles#reader' }
  @{ Id = 'OPS-03'; Area = 'Scope'; Severity = 'Info'; Title = 'No server-side diagnostic bundle for a registered server'; Check = 'no servers/<hostname>/ folder in the export for a registered server'; Recommendation = 'Run Get-AfsServerDiagnostics.ps1 on the server (elevated) and drop the zip under servers\<hostname>\ to include service state, event logs, backup/AV products and disk headroom in the assessment.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-use-debug-cmdlet' }
  # -- Server bundles ----------------------------------------------------------------------------
  @{ Id = 'SRV-01'; Area = 'Server'; Severity = 'High'; Title = 'Storage Sync Agent service or filter drivers not running'; Check = 'FileSyncSvc != Running, AzureStorageSyncMonitor absent, or StorageSync/StorageSyncGuard filter missing'; Recommendation = 'Start the Storage Sync Agent service; if it fails, follow the FileSyncSvc troubleshooting article (certificate, time, proxy). Filter drivers missing usually means a failed agent install - repair/reinstall the agent.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-service-fails-start' }
  @{ Id = 'SRV-02'; Area = 'Server'; Severity = 'Medium'; Title = 'Backup or third-party antivirus product on a tiered server endpoint'; Check = 'backup/AV product in installed programs while the server has tiered endpoints'; Recommendation = 'Server-side backup of tiered files is unsupported (skipped or recalled); back up the Azure file share instead. For antivirus, confirm the vendor honours FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (Defender does) or exclude the endpoint path from full scans.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#backup' }
  @{ Id = 'SRV-03'; Area = 'Server'; Severity = 'Medium'; Title = 'Volume free space is at or below the tiering policy'; Check = 'volume freePercent <= volumeFreeSpacePercent + 5 for a server endpoint volume'; Recommendation = 'Extend the disk, lower the free-space policy, or reduce the local cache (date policy). Below the policy the agent tiers aggressively and users see recalls.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#free-space-on-your-local-disk' }
  @{ Id = 'SRV-04'; Area = 'Server'; Severity = 'Medium'; Title = 'Windows Search or DFS Replication active on a File Sync server'; Check = 'WSearch running with an index scope on an endpoint path, or DFSR feature installed'; Recommendation = 'Windows Search recalls tiered files when it indexes them - exclude endpoint paths or stop the service. DFS-R on the same data as Azure File Sync is only supported in specific migration modes; verify no replication group covers an endpoint path.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#distributed-file-system' }
  @{ Id = 'SRV-05'; Area = 'Server'; Severity = 'High'; Title = 'Server clock is not synchronised'; Check = 'w32tm phase offset > 5 minutes or source = Local CMOS Clock'; Recommendation = 'Fix time synchronisation (domain hierarchy or NTP). Authentication to the Storage Sync Service fails with clock skew.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-installation' }
  @{ Id = 'SRV-06'; Area = 'Server'; Severity = 'Medium'; Title = 'Sync sessions failing in the Telemetry log'; Check = 'event 9102 with HResult != 0 (3 or more in the window) or 9121 persistent per-item errors'; Recommendation = 'Correlate with AFS-01/02; the 9102 HResult identifies the error class (see the sync errors article); per-item errors are listed by FileSyncErrorsReport.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-troubleshoot-sync-errors' }
  @{ Id = 'SRV-07'; Area = 'Server'; Severity = 'Low'; Title = 'Self-service restore (Previous Versions) not enabled on a tiered volume'; Check = 'Get-StorageSyncSelfServiceRestore reports disabled for an endpoint volume'; Recommendation = 'Run Enable-StorageSyncSelfServiceRestore -DriveLetter X so users restore their own previous versions from VSS snapshots without a backup ticket.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-deployment-guide#optional-use-self-service-restore-through-previous-versions-and-vss' }
  @{ Id = 'SRV-08'; Area = 'Server'; Severity = 'Medium'; Title = 'Debug-StorageSyncServer reported a failure'; Check = 'diagnose / network connectivity output contains Fail / Error'; Recommendation = 'Read debug-diagnose.txt and debug-network.txt in the bundle; typical failures are certificate expiry, time skew, proxy without agent configuration, or blocked endpoints.'; Ref = "$L" + 'troubleshoot/azure/azure-storage/files/file-sync/file-sync-use-debug-cmdlet' }
  @{ Id = 'SRV-09'; Area = 'Server'; Severity = 'Low'; Title = 'Large NTFS cluster size on a tiered volume'; Check = 'bytesPerCluster >= 65536 on a server endpoint volume with tiering'; Recommendation = 'Each tiered file occupies one cluster; 64 KiB clusters waste space and reduce tiering savings. Use 4 KiB (or up to 32 KiB) when the volume is next rebuilt.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#free-space-on-your-local-disk' }
  @{ Id = 'SRV-10'; Area = 'Server'; Severity = 'Low'; Title = 'Agent version on the server differs from the registered version'; Check = 'system.json agent version != registeredServer.agentVersion'; Recommendation = 'The server has not reported its new version yet (heartbeat) or the registration is stale; verify FileSyncSvc restarted after the update.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#azure-file-sync-agent-update-policy' }
  @{ Id = 'SRV-11'; Area = 'Server'; Severity = 'Info'; Title = 'Data Deduplication enabled on a tiered volume'; Check = 'Get-DedupVolume enabled on a server endpoint volume'; Recommendation = 'Supported (2016+ with KB4520062 on 2016/2019). Remember MinimumFileAgeDays delays the tiering date policy by the same number of days.'; Ref = "$L" + 'azure/storage/file-sync/file-sync-planning#data-deduplication' }
) | ForEach-Object { [pscustomobject]$_ }
# Rule recommendations are written with a {customer} token rather than a name. Substituting
# here - once, at the source - means the findings, the roadmap and the rule catalog all say the
# right thing without any of them knowing about it. A hardcoded name in this table would appear
# in EVERY customer's report, which is exactly the defect this replaced.
$RuleWho = if ($CustomerName -and $CustomerName -ne 'Customer') { $CustomerName } else { 'your' }
foreach ($r in $Rules) {
  foreach ($p in @('Recommendation', 'Check', 'Title')) {
    if ($r.$p -is [string] -and $r.$p.Contains('{customer}')) { $r.$p = $r.$p.Replace('{customer}', $RuleWho) }
  }
}
$RuleById = @{}; foreach ($r in $Rules) { $RuleById[$r.Id] = $r }

function Get-Catalog {
  $o = New-Object System.Collections.ArrayList
  [void]$o.Add("# Assessment rule catalog (v$ToolVersion)"); [void]$o.Add('')
  [void]$o.Add('| ID | Area | Severity | Finding | Check | Recommendation | Reference |'); [void]$o.Add('|---|---|---|---|---|---|---|')
  foreach ($r in $Rules) { [void]$o.Add("| $($r.Id) | $($r.Area) | $($r.Severity) | $($r.Title) | $($r.Check) | $($r.Recommendation) | [learn]($($r.Ref)) |") }
  return ($o -join "`n") + "`n"
}
if ($ListRules) { Write-Output (Get-Catalog); return }
if (-not $ExportPath) { throw 'ExportPath is required (folder or zip from Export-AzFileSyncEnvironment.ps1), or use -ListRules.' }

# =========================================================================================
# LOAD
# =========================================================================================
function Get-Prop($Obj, [string]$Name, $Default = $null) { if ($null -eq $Obj) { return $Default }; $p = $Obj.PSObject.Properties[$Name]; if ($p -and $null -ne $p.Value) { return $p.Value }; return $Default }
function LoadList([string]$Path) { $o = Load-Json $Path; if ($null -eq $o) { return ,@() }; return ,@($o) }
function Load-Json([string]$Path) { if (-not (Test-Path $Path)) { return $null }; $t = [System.IO.File]::ReadAllText($Path); if ([string]::IsNullOrWhiteSpace($t) -or $t -eq 'null') { return $null }; return ($t | ConvertFrom-Json) }
function To-Date($s) { if (-not $s) { return $null }; try { return [datetime]::Parse([string]$s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { return $null } }
function Leaf([string]$id) { if (-not $id) { return '' }; return $id.Split('/')[-1] }
function HasLock($locks) { return (@($locks | Where-Object { (Get-Prop $_.properties 'level' '') -eq 'CanNotDelete' -or (Get-Prop $_.properties 'level' '') -eq 'ReadOnly' }).Count -gt 0) }
function TagNames($res) { $t = Get-Prop $res 'tags'; if (-not $t) { return '' }; return ((@($t.PSObject.Properties) | ForEach-Object { $_.Name }) -join ',') }
function HasTag($res, [string]$tag) { $t = Get-Prop $res 'tags'; if (-not $t) { return $false }; foreach ($p in $t.PSObject.Properties) { if ($p.Name -ieq $tag) { return $true } }; return $false }

$ExportPath = (Resolve-Path $ExportPath).Path
$tempRoot = $null
if ($ExportPath -like '*.zip') {
  $tempRoot = Join-Path $env:TEMP ("afs-assess-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Expand-Archive -Path $ExportPath -DestinationPath $tempRoot -Force
  $root = $tempRoot
  if (-not $OutputPath) { $OutputPath = Split-Path $ExportPath -Parent }
} else { $root = $ExportPath; if (-not $OutputPath) { $OutputPath = $root } }
if (-not (Test-Path (Join-Path $root 'manifest.json'))) { throw "Not an export folder (manifest.json missing): $root" }
$manifest = Load-Json (Join-Path $root 'manifest.json')
$inventory = Load-Json (Join-Path $root 'inventory.json')
$exportErrors = (LoadList (Join-Path $root 'errors.json'))
$exportedAt = To-Date (Get-Prop $manifest 'exportedAtUtc'); if (-not $exportedAt) { $exportedAt = (Get-Date).ToUniversalTime() }
Write-Host "Assessing export at $root (exported $($exportedAt.ToString('u')))"

# Sync services
$syncServices = @()
foreach ($d in @(Get-ChildItem (Join-Path $root 'storagesync') -Directory -ErrorAction SilentlyContinue)) {
  $syncServices += [pscustomobject]@{
    dir = $d.Name; service = Load-Json (Join-Path $d.FullName 'service.json'); groups = (LoadList (Join-Path $d.FullName 'syncgroups.json'))
    cloudEndpoints = (LoadList (Join-Path $d.FullName 'cloudendpoints.json')); serverEndpoints = (LoadList (Join-Path $d.FullName 'serverendpoints.json'))
    servers = (LoadList (Join-Path $d.FullName 'registeredservers.json')); pecs = (LoadList (Join-Path $d.FullName 'privateendpointconnections.json'))
    locks = (LoadList (Join-Path $d.FullName 'locks.json')); metrics = Load-Json (Join-Path $d.FullName 'metrics.json')
  }
}
# Storage accounts
$accounts = @()
foreach ($d in @(Get-ChildItem (Join-Path $root 'storage') -Directory -ErrorAction SilentlyContinue)) {
  $acct = Load-Json (Join-Path $d.FullName 'account.json'); if (-not $acct) { continue }
  $sh = Load-Json (Join-Path $d.FullName 'shares.json')
  $accounts += [pscustomobject]@{
    dir = $d.Name; account = $acct; id = $acct.id; name = $acct.name; location = $acct.location
    fileService = Load-Json (Join-Path $d.FullName 'fileservice.json')
    shares = @(Get-Prop $sh 'shares' @()); snapshots = @(Get-Prop $sh 'snapshots' @()); softDeleted = @(Get-Prop $sh 'softDeleted' @())
    diagAccount = (LoadList (Join-Path $d.FullName 'diagnostics-account.json')); diagFile = (LoadList (Join-Path $d.FullName 'diagnostics-fileservice.json'))
    roles = (LoadList (Join-Path $d.FullName 'roleassignments.json')); locks = (LoadList (Join-Path $d.FullName 'locks.json'))
    defender = Load-Json (Join-Path $d.FullName 'defender.json'); metrics = Load-Json (Join-Path $d.FullName 'metrics.json')
  }
}
$accountById = @{}; foreach ($a in $accounts) { $accountById[$a.id.ToLower()] = $a }
$defenderPricing = @{}
foreach ($f in @(Get-ChildItem (Join-Path $root 'defender') -Filter '*-pricing-StorageAccounts.json' -ErrorAction SilentlyContinue)) { $p = Load-Json $f.FullName; if ($p) { $sid = ([string]$p.id).Split('/')[2]; $defenderPricing[$sid] = Get-Prop $p.properties 'pricingTier' '' } }
# Vaults
$vaults = @()
foreach ($d in @(Get-ChildItem (Join-Path $root 'backup') -Directory -ErrorAction SilentlyContinue)) {
  $v = Load-Json (Join-Path $d.FullName 'vault.json'); if (-not $v) { continue }
  $vaults += [pscustomobject]@{
    dir = $d.Name; vault = $v; id = $v.id; name = $v.name; location = $v.location
    vaultconfig = Load-Json (Join-Path $d.FullName 'vaultconfig.json'); storageconfig = Load-Json (Join-Path $d.FullName 'storageconfig.json')
    policies = (LoadList (Join-Path $d.FullName 'policies.json')); items = (LoadList (Join-Path $d.FullName 'protecteditems.json')); jobs = (LoadList (Join-Path $d.FullName 'jobs.json'))
    guards = (LoadList (Join-Path $d.FullName 'resourceguardproxies.json')); diag = (LoadList (Join-Path $d.FullName 'diagnostics.json')); locks = (LoadList (Join-Path $d.FullName 'locks.json'))
  }
}
$coverage = (LoadList (Join-Path $root 'backup/share-coverage.json'))
$dpVaults = @(Get-ChildItem (Join-Path $root 'backup-dataprotection') -Directory -ErrorAction SilentlyContinue)
$zones = (LoadList (Join-Path $root 'network/privatednszones.json'))
$pes = (LoadList (Join-Path $root 'network/privateendpoints.json'))
$alerts = (LoadList (Join-Path $root 'monitor/metricalerts.json'))
$topology = (LoadList (Join-Path $root 'network/topology.json'))
# Server bundles: servers/<host>/(system.json | <host>-afs-server-*/system.json | zip)
$serverBundles = @{}
$serversRoot = Join-Path $root 'servers'
if (Test-Path $serversRoot) {
  foreach ($d in @(Get-ChildItem $serversRoot -Directory)) {
    foreach ($z in @(Get-ChildItem $d.FullName -Filter '*.zip' -ErrorAction SilentlyContinue)) { $x = Join-Path $d.FullName ([IO.Path]::GetFileNameWithoutExtension($z.Name)); if (-not (Test-Path $x)) { Expand-Archive -Path $z.FullName -DestinationPath $x -Force } }
    $sys = Get-ChildItem $d.FullName -Filter 'system.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sys) { continue }
    $b = Split-Path $sys.FullName -Parent
    $system = Load-Json $sys.FullName
    $hn = [string](Get-Prop $system 'hostname' $d.Name)
    $serverBundles[$hn.ToLower()] = [pscustomobject]@{ dir = $b; hostname = $hn; system = $system; services = Load-Json (Join-Path $b 'services.json'); volumes = Load-Json (Join-Path $b 'volumes.json'); programs = Load-Json (Join-Path $b 'programs.json'); digest = (LoadList (Join-Path $b 'sync-session-digest.json')); telemetry = (LoadList (Join-Path $b 'events-telemetry.json')); ssr = (LoadList (Join-Path $b 'selfservicerestore.json')); w32tm = $(if (Test-Path (Join-Path $b 'w32tm.txt')) { Get-Content (Join-Path $b 'w32tm.txt') -Raw } else { '' }); diagnose = $(if (Test-Path (Join-Path $b 'debug-diagnose.txt')) { Get-Content (Join-Path $b 'debug-diagnose.txt') -Raw } else { '' }); network = $(if (Test-Path (Join-Path $b 'debug-network.txt')) { Get-Content (Join-Path $b 'debug-network.txt') -Raw } else { '' }) }
  }
}

# =========================================================================================
# EVALUATE
# =========================================================================================
$Findings = New-Object System.Collections.ArrayList
function Add-Finding([string]$Id, [string]$Resource, [string]$Evidence, [string]$Severity, [string]$Note) {
  $r = $RuleById[$Id]; if (-not $r) { throw "unknown rule $Id" }
  $sev = if ($Severity) { $Severity } else { $r.Severity }
  $rec = $r.Recommendation; if ($Note) { $rec = "$Note $rec" }
  [void]$Findings.Add([pscustomobject]@{ id = $Id; area = $r.Area; severity = $sev; title = $r.Title; resource = $Resource; evidence = $Evidence; recommendation = $rec; reference = $r.Ref })
}
$afsAccountIds = @{}   # storage account id (lower) -> list of "svc/group/share"
$afsShareKeys = @{}    # "<account>/<share>" lower -> $true
$hourAgo = $exportedAt.AddHours(-1); $dayAgo = $exportedAt.AddHours(-24); $twoDaysAgo = $exportedAt.AddHours(-48); $ninetyDays = $exportedAt.AddDays(90)

# -- 1. Azure File Sync ----------------------------------------------------------------------
foreach ($s in $syncServices) {
  $svc = $s.service; $svcName = $svc.name; $sp = $svc.properties
  $approvedPecs = @($s.pecs | Where-Object { (Get-Prop (Get-Prop $_.properties 'privateLinkServiceConnectionState') 'status' '') -eq 'Approved' })
  $itp = Get-Prop $sp 'incomingTrafficPolicy' 'AllowAllTraffic'
  if ($itp -eq 'AllowVirtualNetworksOnly' -and $approvedPecs.Count -eq 0) { Add-Finding 'AFS-11' $svcName "incomingTrafficPolicy=$itp, approved private endpoint connections=0" }
  if ($PrivateTrafficRequired) {
    if ($approvedPecs.Count -eq 0) { Add-Finding 'NET-05' $svcName "approved private endpoint connections=0, incomingTrafficPolicy=$itp" }
    elseif ($itp -eq 'AllowAllTraffic') { Add-Finding 'NET-07' $svcName "approved private endpoints=$($approvedPecs.Count), incomingTrafficPolicy=AllowAllTraffic" }
  }
  $useMi = [string](Get-Prop $sp 'useIdentity' 'false')
  if ($useMi -ne 'True' -and $useMi -ne 'true') { Add-Finding 'AFS-12' $svcName "useIdentity=$useMi; identity=$(Get-Prop (Get-Prop $svc 'identity') 'type' 'none')" }
  if (-not (HasLock $s.locks)) { Add-Finding 'AFS-18' $svcName 'no CanNotDelete/ReadOnly lock' }
  if (-not (HasTag $svc 'owner') -or -not (HasTag $svc 'environment')) { Add-Finding 'OPS-01' "Storage Sync Service $svcName" "tags: $(TagNames $svc)" }
  # servers
  foreach ($srv in $s.servers) { $p = $srv.properties; $name = Get-Prop $p 'friendlyName' (Get-Prop $p 'serverName' $srv.name); $res = "$svcName / server $name"
    $hb = To-Date (Get-Prop $p 'lastHeartBeat'); if ($hb -and $hb -lt $hourAgo) { Add-Finding 'AFS-04' $res "lastHeartBeat=$($hb.ToString('u')) (export $($exportedAt.ToString('u')))" }
    $st = [string](Get-Prop $p 'agentVersionStatus' ''); $exp = To-Date (Get-Prop $p 'agentVersionExpirationDate')
    if ($st -in @('Expired', 'Blocked')) { Add-Finding 'AFS-05' $res "agentVersionStatus=$st agentVersion=$(Get-Prop $p 'agentVersion' '')" }
    elseif ($exp -and $exp -lt $ninetyDays) { Add-Finding 'AFS-05' $res "agentVersionExpirationDate=$($exp.ToString('yyyy-MM-dd')) agentVersion=$(Get-Prop $p 'agentVersion' '')" 'Medium' }
    $av = [string](Get-Prop $p 'agentVersion' ''); if ($av -match '^(\d+)\.') { if ([int]$Matches[1] -lt $LatestAgentMajor) { Add-Finding 'AFS-06' $res "agentVersion=$av (latest major $LatestAgentMajor)" } }
    $osv = [string](Get-Prop $p 'serverOSVersion' ''); if ($osv -and $osv -notmatch '^10\.0\.') { Add-Finding 'AFS-07' $res "serverOSVersion=$osv" }
    elseif ($osv -match '^10\.0\.14393') { Add-Finding 'AFS-07' $res "serverOSVersion=$osv (Windows Server 2016 - extended support ends January 2027)" 'Low' 'Plan the upgrade before support ends.' }
    if (Get-Prop $p 'clusterName') { Add-Finding 'AFS-15' $res "clusterName=$(Get-Prop $p 'clusterName')" }
    if (($useMi -eq 'True' -or $useMi -eq 'true') -and (Get-Prop $p 'activeAuthType' '') -and (Get-Prop $p 'activeAuthType' '') -ne 'ManagedIdentity') { Add-Finding 'AFS-19' $res "activeAuthType=$(Get-Prop $p 'activeAuthType')" }
    $hn = ([string]$name).Split('.')[0].ToLower()
    if (-not $serverBundles.ContainsKey($hn)) { Add-Finding 'OPS-03' $res 'no servers/<hostname>/ bundle in the export' }
  }
  # groups + endpoints
  foreach ($g in $s.groups) {
    $ces = @($s.cloudEndpoints | Where-Object { $_.id -like "$($g.id)/*" }); $ses = @($s.serverEndpoints | Where-Object { $_.id -like "$($g.id)/*" })
    if ($ses.Count -eq 0) { Add-Finding 'AFS-17' "$svcName / $($g.name)" "server endpoints=0" }
    foreach ($c in $ces) { $p = $c.properties; $said = [string](Get-Prop $p 'storageAccountResourceId' ''); $share = [string](Get-Prop $p 'azureFileShareName' ''); $res = "$svcName / $($g.name) / cloud endpoint $(Leaf $said)/$share"
      if ($said) { $k = $said.ToLower(); if (-not $afsAccountIds.ContainsKey($k)) { $afsAccountIds[$k] = New-Object System.Collections.ArrayList }; [void]$afsAccountIds[$k].Add("$svcName/$($g.name)/$share"); $afsShareKeys[("$(Leaf $said)/$share").ToLower()] = $true
        if (-not $accountById.ContainsKey($k)) { Add-Finding 'AFS-13' $res "storageAccountResourceId=$said" }
        else { $a = $accountById[$k]
          if ($a.location -and $svc.location -and ($a.location -ne $svc.location)) { Add-Finding 'AFS-16' $res "sync service $($svc.location) vs storage account $($a.location)" }
          $na = Get-Prop $a.account.properties 'networkAcls'; $da = Get-Prop $na 'defaultAction' 'Allow'; $byp = [string](Get-Prop $na 'bypass' '')
          $rar = @(Get-Prop $na 'resourceAccessRules' @() | Where-Object { ([string](Get-Prop $_ 'resourceId' '')) -match 'Microsoft\.StorageSync' })
          $pecount = @(Get-Prop $a.account.properties 'privateEndpointConnections' @()).Count
          if ($da -eq 'Deny' -and $byp -notmatch 'AzureServices' -and $rar.Count -eq 0) { Add-Finding 'AFS-14' $res "defaultAction=Deny bypass='$byp' storageSync resource rules=0 privateEndpoints=$pecount" $(if ($pecount -gt 0) { 'Medium' } else { 'High' }) }
          if ((Get-Prop $a.account.properties 'publicNetworkAccess' 'Enabled') -eq 'Disabled') { Add-Finding 'SEC-05' $res 'publicNetworkAccess=Disabled' }
          if ($PrivateTrafficRequired) {
            if ($pecount -eq 0) { Add-Finding 'NET-06' "storage account $($a.name)" "privateEndpointConnections=0 (cloud endpoint $svcName/$($g.name)/$share)" }
            elseif ($da -eq 'Allow') { Add-Finding 'NET-08' "storage account $($a.name)" "privateEndpointConnections=$pecount, networkAcls.defaultAction=Allow" }
          }
        }
      }
      $ces2 = Get-Prop $p 'changeEnumerationStatus'; $lce = To-Date (Get-Prop (Get-Prop $ces2 'lastCompletedEnumeration') 'completedTimestamp')
      if (-not $lce) { Add-Finding 'AFS-08' $res 'no completed change enumeration recorded' } elseif ($lce -lt $twoDaysAgo) { Add-Finding 'AFS-08' $res "lastCompletedEnumeration=$($lce.ToString('u'))" }
    }
    $paths = @()
    foreach ($se in $ses) { $p = $se.properties; $ss = Get-Prop $p 'syncStatus'; $ct = Get-Prop $p 'cloudTieringStatus'; $sname = Get-Prop $p 'serverName' (Get-Prop $p 'friendlyName' $se.name); $path = [string](Get-Prop $p 'serverLocalPath' ''); $res = "$svcName / $($g.name) / $sname $path"
      $paths += [pscustomobject]@{ server = [string](Get-Prop $p 'serverResourceId' $sname); path = $path.TrimEnd('\').ToLower(); res = $res }
      $ch = Get-Prop $ss 'combinedHealth' ''; if ($ch -and $ch -ne 'Healthy') { Add-Finding 'AFS-01' $res "combinedHealth=$ch upload=$(Get-Prop $ss 'uploadHealth' '') download=$(Get-Prop $ss 'downloadHealth' '') activity=$(Get-Prop $ss 'syncActivity' '')" }
      $pers = Get-Prop $ss 'totalPersistentFilesNotSyncingCount' 0; $pie = Get-Prop (Get-Prop $ss 'uploadStatus') 'lastSyncPerItemErrorCount' 0
      if ([int64]$pers -gt 0 -or [int64]$pie -gt 0) { Add-Finding 'AFS-02' $res "persistentFilesNotSyncing=$pers lastSyncPerItemErrorCount=$pie" }
      $up = To-Date (Get-Prop (Get-Prop $ss 'uploadStatus') 'lastSyncSuccessTimestamp'); $dn = To-Date (Get-Prop (Get-Prop $ss 'downloadStatus') 'lastSyncSuccessTimestamp')
      if (($up -and $up -lt $dayAgo) -or ($dn -and $dn -lt $dayAgo)) { Add-Finding 'AFS-03' $res "lastSyncSuccess upload=$(if ($up) { $up.ToString('u') } else { 'n/a' }) download=$(if ($dn) { $dn.ToString('u') } else { 'n/a' })" }
      if ($path -match '^[Cc]:\\') { Add-Finding 'AFS-09' $res "serverLocalPath=$path" }
      $tier = [string](Get-Prop $p 'cloudTiering' 'off')
      if ($tier -ieq 'off') { Add-Finding 'TIER-01' $res 'cloudTiering=off' }
      else {
        $th = Get-Prop $ct 'health' ''; $lr = Get-Prop $ct 'lastCloudTieringResult' 0
        if (($th -and $th -ne 'Healthy') -or ([int64]$lr -ne 0)) { Add-Finding 'TIER-02' $res "tiering health=$th lastCloudTieringResult=$lr" }
        if ((Get-Prop (Get-Prop $ct 'lowDiskMode') 'state' '') -eq 'Enabled') { Add-Finding 'TIER-03' $res "lowDiskMode=Enabled" }
        $vfs = Get-Prop $p 'volumeFreeSpacePercent' 20; if ([int]$vfs -lt 10) { Add-Finding 'TIER-04' $res "volumeFreeSpacePercent=$vfs" }
        $chr = Get-Prop (Get-Prop $ct 'cachePerformance') 'cacheHitRatio'; if ($null -ne $chr -and [double]$chr -gt 0 -and [double]$chr -lt 0.8) { Add-Finding 'TIER-05' $res "cacheHitRatio=$chr" }
      }
    }
    for ($i = 0; $i -lt $paths.Count; $i++) { for ($j = 0; $j -lt $paths.Count; $j++) { if ($i -ne $j -and $paths[$i].server -eq $paths[$j].server -and $paths[$i].path -and $paths[$j].path.StartsWith($paths[$i].path + '\')) { Add-Finding 'AFS-10' $paths[$j].res "nested under $($paths[$i].path)" } } }
  }
  # metrics: recall
  $rm = Get-Prop $s.metrics 'StorageSyncRecallTotalSizeBytes'
  foreach ($mv in @(Get-Prop $rm 'value' @())) { foreach ($ts in @(Get-Prop $mv 'timeseries' @())) { $dim = (@(Get-Prop $ts 'metadatavalues' @()) | ForEach-Object { $_.value }) -join '/'; foreach ($pt in @(Get-Prop $ts 'data' @())) { $tot = Get-Prop $pt 'total' 0; if ([double]$tot -gt 500GB) { Add-Finding 'TIER-06' "$svcName / $dim" "recalled $([math]::Round($tot / 1GB)) GiB on $(Get-Prop $pt 'timeStamp' '')" } } } }
  if (@($alerts | Where-Object { @(Get-Prop $_.properties 'scopes' @()) -contains $svc.id }).Count -eq 0) { Add-Finding 'MON-01' $svcName 'no metric alert rule scoped to the service' }
}

# -- 2. Storage accounts ---------------------------------------------------------------------
$protectedKeys = @{}; foreach ($c in $coverage) { if ((Get-Prop $c 'protected' $false)) { $protectedKeys[("$($c.storageAccount)/$($c.share)").ToLower()] = $true } }
$unprotectedRegions = @{}
foreach ($a in $accounts) {
  if ($a.shares.Count -eq 0) { continue }   # blob-only accounts are out of scope
  $p = $a.account.properties; $isAfs = $afsAccountIds.ContainsKey($a.id.ToLower()); $res = "storage account $($a.name)"; $hasProtected = @($a.shares | Where-Object { $protectedKeys.ContainsKey(("$($a.name)/$($_.name)").ToLower()) }).Count -gt 0
  $tag = if ($isAfs) { ' (File Sync cloud endpoint)' } else { '' }
  if ((Get-Prop $p 'supportsHttpsTrafficOnly' $true) -eq $false) { Add-Finding 'SEC-01' "$res$tag" 'supportsHttpsTrafficOnly=false' }
  $tls = [string](Get-Prop $p 'minimumTlsVersion' 'TLS1_0'); if ($tls -notin @('TLS1_2', 'TLS1_3')) { Add-Finding 'SEC-02' "$res$tag" "minimumTlsVersion=$tls" }
  $na = Get-Prop $p 'networkAcls'; $pna = Get-Prop $p 'publicNetworkAccess' 'Enabled'; $da = Get-Prop $na 'defaultAction' 'Allow'
  if ($pna -ne 'Disabled' -and $da -eq 'Allow') { Add-Finding 'SEC-03' "$res$tag" "publicNetworkAccess=$pna defaultAction=$da" $(if ($isAfs -or $hasProtected) { 'Medium' } else { 'Low' }) }
  $ska = Get-Prop $p 'allowSharedKeyAccess' $true
  if ($ska -eq $false -and $hasProtected) { Add-Finding 'BKP-18' "$res" 'allowSharedKeyAccess=false with protected shares' }
  elseif ($ska -ne $false) { Add-Finding 'SEC-04' "$res$tag" "allowSharedKeyAccess=$ska" $(if ($isAfs -or $hasProtected) { 'Info' } else { 'Medium' }) }
  $kct = Get-Prop $p 'keyCreationTime'; $k1 = To-Date (Get-Prop $kct 'key1'); $k2 = To-Date (Get-Prop $kct 'key2'); $kp = Get-Prop (Get-Prop $p 'keyPolicy') 'keyExpirationPeriodInDays'
  $oldKey = ($k1 -and $k1 -lt $exportedAt.AddDays(-365)) -or ($k2 -and $k2 -lt $exportedAt.AddDays(-365))
  if ($oldKey -or -not $kp) { Add-Finding 'SEC-06' "$res$tag" "key1=$(if ($k1) { $k1.ToString('yyyy-MM-dd') } else { '?' }) key2=$(if ($k2) { $k2.ToString('yyyy-MM-dd') } else { '?' }) keyExpirationPeriodInDays=$(if ($kp) { $kp } else { 'none' })" }
  $dso = Get-Prop (Get-Prop $p 'azureFilesIdentityBasedAuthentication') 'directoryServiceOptions' 'None'
  if ($dso -eq 'None') { $nonAfsShares = @($a.shares | Where-Object { -not $afsShareKeys.ContainsKey(("$($a.name)/$($_.name)").ToLower()) }).Count; Add-Finding 'SEC-07' "$res$tag" "directoryServiceOptions=None; shares not in File Sync=$nonAfsShares" $(if ($nonAfsShares -gt 0) { 'Medium' } else { 'Low' }) }
  $smb = Get-Prop (Get-Prop (Get-Prop $a.fileService 'properties') 'protocolSettings') 'smb'
  $smbSet = if ($smb) { @($smb.PSObject.Properties | Where-Object { $_.Value }).Count } else { 0 }
  if ($smbSet -eq 0) { Add-Finding 'SEC-08' "$res$tag" 'protocolSettings.smb = defaults (SMB2.1/3.0/3.1.1, NTLMv2+Kerberos, AES-128-CCM allowed)' }
  $sid = $a.id.Split('/')[2]; $tier = $(if ($defenderPricing.ContainsKey($sid)) { $defenderPricing[$sid] } else { 'unknown' }); $perAcct = Get-Prop (Get-Prop $a.defender 'properties') 'isEnabled'
  if ($tier -ne 'Standard' -and -not $perAcct) { Add-Finding 'SEC-09' "$res$tag" "subscription pricing=$tier per-account=$(if ($null -eq $perAcct) { 'n/a' } else { $perAcct })" }
  if (($isAfs -or $hasProtected) -and -not (HasLock $a.locks)) { Add-Finding 'SEC-10' "$res$tag" 'no CanNotDelete/ReadOnly lock' }
  if ((Get-Prop $p 'allowBlobPublicAccess' $false) -eq $true) { Add-Finding 'SEC-11' $res 'allowBlobPublicAccess=true' }
  if ((Get-Prop $p 'allowCrossTenantReplication' $false) -eq $true) { Add-Finding 'SEC-12' $res 'allowCrossTenantReplication=true' }
  $priv = @($a.roles | Where-Object { $_.principalType -eq 'User' -and $_.scope -eq $a.id -and $_.roleName -in @('Owner', 'Contributor', 'Storage Account Contributor') })
  if ($priv.Count -gt 0) { Add-Finding 'SEC-13' $res "$($priv.Count) direct user assignment(s): $(($priv | ForEach-Object { $_.roleName }) -join ', ')" }
  if ((Get-Prop (Get-Prop $p 'encryption') 'keySource' 'Microsoft.Storage') -eq 'Microsoft.Storage') { Add-Finding 'SEC-14' $res 'keySource=Microsoft.Storage' }
  if ((Get-Prop $p 'isSftpEnabled' $false) -eq $true -or (Get-Prop $p 'isLocalUserEnabled' $false) -eq $true) { Add-Finding 'SEC-15' $res "isSftpEnabled=$(Get-Prop $p 'isSftpEnabled' $false) isLocalUserEnabled=$(Get-Prop $p 'isLocalUserEnabled' $false)" }
  $sku = [string]$a.account.sku.name
  if ($sku -like '*_LRS') { Add-Finding 'DATA-01' "$res$tag" "sku=$sku" $(if ($isAfs -or $hasProtected) { 'Medium' } else { 'Low' }) }
  if ($sku -like '*RAGRS' -or $sku -like '*RAGZRS') { Add-Finding 'DATA-07' $res "sku=$sku" }
  $sdp = Get-Prop (Get-Prop $a.fileService 'properties') 'shareDeleteRetentionPolicy'; $sde = Get-Prop $sdp 'enabled' $false; $sdd = Get-Prop $sdp 'days' 0
  if (-not $sde) { Add-Finding 'DATA-02' "$res$tag" 'shareDeleteRetentionPolicy.enabled=false' } elseif ([int]$sdd -lt 14) { Add-Finding 'DATA-02' "$res$tag" "shareDeleteRetentionPolicy.days=$sdd" 'Medium' }
  if ($a.account.kind -eq 'StorageV2' -and (Get-Prop $p 'largeFileSharesState' 'Disabled') -ne 'Enabled' -and $isAfs) { Add-Finding 'DATA-06' "$res$tag" "largeFileSharesState=$(Get-Prop $p 'largeFileSharesState' 'Disabled')" }
  if ($a.softDeleted.Count -gt 0) { Add-Finding 'DATA-05' $res "$($a.softDeleted.Count) soft-deleted share(s): $(($a.softDeleted | ForEach-Object { $_.name }) -join ', ')" }
  if (-not (HasTag $a.account 'owner') -or -not (HasTag $a.account 'environment')) { Add-Finding 'OPS-01' $res "tags: $(TagNames $a.account)" }
  if ($isAfs -and @($alerts | Where-Object { @(Get-Prop $_.properties 'scopes' @()) -contains $a.id }).Count -eq 0) { Add-Finding 'MON-02' $res 'no metric alert rule scoped to the account' }
  if ($isAfs -and $a.diagFile.Count -eq 0) { Add-Finding 'MON-03' $res 'no diagnostic settings on fileServices/default' }
  foreach ($sh in $a.shares) { $spp = $sh.properties; $q = Get-Prop $spp 'shareQuota' 0; $u = Get-Prop $spp 'shareUsageBytes' 0; $sres = "$($a.name)/$($sh.name)"; $isAfsShare = $afsShareKeys.ContainsKey($sres.ToLower())
    if ([double]$q -gt 0) { $pct = 100.0 * [double]$u / ([double]$q * 1GB); if ($pct -gt 95) { Add-Finding 'DATA-03' $sres "used $([math]::Round($pct,1)) % of $q GiB" 'High' } elseif ($pct -gt 80) { Add-Finding 'DATA-03' $sres "used $([math]::Round($pct,1)) % of $q GiB" $(if ($pct -gt 90) { 'Medium' } else { 'Low' }) } }
    $snaps = @($a.snapshots | Where-Object { $_.name -eq $sh.name }).Count; if ($snaps -gt 150) { Add-Finding 'DATA-04' $sres "snapshots=$snaps" }
    if (-not $protectedKeys.ContainsKey($sres.ToLower())) { Add-Finding 'BKP-01' $sres "no protected item for this share$(if ($isAfsShare) { ' - Azure File Sync cloud endpoint: server-side backup of tiered files is unsupported' })" 'High' $(if ($isAfsShare) { 'Azure File Sync cloud endpoint.' } else { $null }); $unprotectedRegions[$a.location] = $true }
  }
}
foreach ($reg in $unprotectedRegions.Keys) { if (@($vaults | Where-Object { $_.location -eq $reg }).Count -eq 0) { Add-Finding 'BKP-14' "region $reg" "unprotected shares in $reg, Recovery Services vaults in $reg = 0" } }

# -- 3. Azure Backup ------------------------------------------------------------------------
$vaultedRegions = @('uksouth', 'ukwest', 'southeastasia', 'eastasia', 'westcentralus', 'centralus', 'centralindia', 'northeurope', 'australiaeast', 'westus', 'eastus', 'southindia', 'francecentral', 'canadacentral', 'northcentralus', 'eastus2', 'australiasoutheast', 'germanynorth', 'francesouth', 'westus2', 'brazilsouth', 'japanwest', 'germanywestcentral', 'canadaeast', 'koreasouth', 'jioindiawest', 'koreacentral', 'southafricawest', 'japaneast', 'norwayeast', 'switzerlandwest', 'norwaywest', 'southafricanorth', 'uaenorth', 'westeurope', 'swedencentral', 'switzerlandnorth', 'swedensouth', 'brazilsoutheast', 'uaecentral', 'italynorth', 'jioindiacentral', 'westus3', 'australiacentral', 'australiacentral2', 'newzealandnorth')
foreach ($v in $vaults) {
  $vp = $v.vault.properties; $sec = Get-Prop $vp 'securitySettings'; $red = Get-Prop $vp 'redundancySettings'; $res = "vault $($v.name)"
  $sds = Get-Prop $sec 'softDeleteSettings'; $sdState = [string](Get-Prop $sds 'softDeleteState' (Get-Prop (Get-Prop $v.vaultconfig 'properties') 'softDeleteFeatureState' '')); $ess = [string](Get-Prop $sds 'enhancedSecurityState' (Get-Prop (Get-Prop $v.vaultconfig 'properties') 'enhancedSecurityState' ''))
  if ($sdState -notin @('Enabled', 'AlwaysON')) { Add-Finding 'BKP-06' $res "softDeleteState=$sdState" } elseif ($sdState -ne 'AlwaysON') { Add-Finding 'BKP-06' $res "softDeleteState=$sdState enhancedSecurityState=$ess retentionDays=$(Get-Prop $sds 'softDeleteRetentionPeriodInDays' 14) (not always-on)" 'Medium' }
  $imm = [string](Get-Prop (Get-Prop $sec 'immutabilitySettings') 'state' 'Disabled'); if ($imm -notin @('Unlocked', 'Locked')) { Add-Finding 'BKP-07' $res "immutability=$imm" }
  $mua = Get-Prop $sec 'multiUserAuthorization'; $muaState = if ($mua -is [string]) { $mua } else { [string](Get-Prop $mua 'state' 'Disabled') }
  if ($muaState -ne 'Enabled' -and $v.guards.Count -eq 0) { Add-Finding 'BKP-08' $res "multiUserAuthorization=$muaState resourceGuardProxies=0" }
  $redu = [string](Get-Prop $red 'standardTierStorageRedundancy' (Get-Prop (Get-Prop $v.storageconfig 'properties') 'storageModelType' '')); $crr = [string](Get-Prop $red 'crossRegionRestore' (Get-Prop (Get-Prop $v.storageconfig 'properties') 'crossRegionRestoreFlag' ''))
  $fsItems = @($v.items | Where-Object { (Get-Prop $_.properties 'workloadType' '') -eq 'AzureFileShare' })
  if ($redu -eq 'LocallyRedundant') { Add-Finding 'BKP-09' $res "standardTierStorageRedundancy=$redu (protected items=$($v.items.Count))" $(if ($v.items.Count -eq 0) { 'Low' } else { 'Medium' }) }
  elseif ($redu -like 'Geo*' -and $crr -notin @('Enabled', 'True', 'true')) { Add-Finding 'BKP-10' $res "crossRegionRestore=$crr" }
  $alertsFail = [string](Get-Prop (Get-Prop (Get-Prop $vp 'monitoringSettings') 'azureMonitorAlertSettings') 'alertsForAllJobFailures' 'Disabled'); if ($alertsFail -ne 'Enabled') { Add-Finding 'BKP-11' $res "alertsForAllJobFailures=$alertsFail" }
  if ($v.diag.Count -eq 0) { Add-Finding 'BKP-12' $res 'no diagnostic settings' }
  if (-not (HasLock $v.locks)) { Add-Finding 'BKP-16' $res 'no CanNotDelete/ReadOnly lock' }
  if (-not (HasTag $v.vault 'owner') -or -not (HasTag $v.vault 'environment')) { Add-Finding 'OPS-01' $res "tags: $(TagNames $v.vault)" }
  foreach ($pol in @($v.policies | Where-Object { (Get-Prop $_.properties 'backupManagementType' '') -eq 'AzureStorage' })) { $pp = $pol.properties; $pres = "$res / policy $($pol.name)"
    if (-not (Get-Prop $pp 'vaultRetentionPolicy')) { $supported = ($vaultedRegions -contains ([string]$v.location).ToLower()); Add-Finding 'BKP-04' $pres "no vaultRetentionPolicy (snapshot tier only); vault region $($v.location) vaulted-tier support: $(if ($supported) { 'yes' } else { 'check the support matrix' })" }
    $ret = Get-Prop $pp 'retentionPolicy'; $dr = [int](Get-Prop (Get-Prop (Get-Prop $ret 'dailySchedule') 'retentionDuration') 'count' 0)
    $hasLong = (Get-Prop $ret 'weeklySchedule') -or (Get-Prop $ret 'monthlySchedule') -or (Get-Prop $ret 'yearlySchedule')
    if ($dr -lt 30 -or -not $hasLong) { Add-Finding 'BKP-05' $pres "daily retention=$dr days; weekly/monthly/yearly=$(if ($hasLong) { 'yes' } else { 'no' })" }
    if ((Get-Prop (Get-Prop $pp 'schedulePolicy') 'scheduleRunFrequency' '') -eq 'Daily') { Add-Finding 'BKP-13' $pres "scheduleRunFrequency=Daily at $(@(Get-Prop (Get-Prop $pp 'schedulePolicy') 'scheduleRunTimes' @()) -join ',') $(Get-Prop $pp 'timeZone' '')" }
  }
  foreach ($it in $v.items) { $ip = $it.properties; $ires = "$res / $(Get-Prop $ip 'friendlyName' $it.name)"; $wt = Get-Prop $ip 'workloadType' ''
    if ($wt -eq 'AzureFileShare') {
      $lbs = [string](Get-Prop $ip 'lastBackupStatus' ''); $ps = [string](Get-Prop $ip 'protectionState' '')
      if (($lbs -and $lbs -ne 'Healthy') -or ($ps -and $ps -ne 'Protected')) { Add-Finding 'BKP-02' $ires "lastBackupStatus=$lbs protectionState=$ps lastBackupTime=$(Get-Prop $ip 'lastBackupTime' '')" }
      if ((Get-Prop $ip 'isScheduledForDeferredDelete' $false) -eq $true) { Add-Finding 'BKP-15' $ires "deferredDeleteTimeRemaining=$(Get-Prop $ip 'deferredDeleteTimeRemaining' '')" }
    } else { Add-Finding 'BKP-19' $ires "workloadType=$wt state=$(Get-Prop $ip 'protectionState' '')" }
  }
  $failed = @($v.jobs | Where-Object { (Get-Prop $_.properties 'status' '') -eq 'Failed' })
  if ($failed.Count -gt 0) { Add-Finding 'BKP-03' $res "$($failed.Count) failed job(s): $((($failed | Select-Object -First 5) | ForEach-Object { "$(Get-Prop $_.properties 'operation' '') $(Get-Prop $_.properties 'entityFriendlyName' '') $(Get-Prop $_.properties 'startTime' '')" }) -join '; ')" }
}
if ($dpVaults.Count -gt 0) { Add-Finding 'BKP-17' 'subscription scope' "$($dpVaults.Count) Data Protection vault(s): $(($dpVaults | ForEach-Object { $_.Name }) -join ', ')" }

# -- 4. Networking ------------------------------------------------------------------------
if ($zones.Count -eq 0 -and $pes.Count -eq 0) { Add-Finding 'NET-01' 'estate' 'no privatelink.file / privatelink.afs zones, no storage or File Sync private endpoints' $(if ($PrivateTrafficRequired) { 'High' } else { 'Info' }) $(if ($PrivateTrafficRequired) { 'Private routing is REQUIRED by the customer: today every byte of sync traffic uses the public endpoints.' } else { $null }) }
if ($PrivateTrafficRequired) {
  if ($vaults.Count -gt 0 -or $coverage.Count -gt 0) { Add-Finding 'NET-09' 'Azure Backup for Azure Files' 'design note (no action on the network)' }
  $gw = @($topology | Where-Object { ([string](Get-Prop $_ 'type' '')) -match 'expressRouteCircuits|virtualNetworkGateways|expressRouteGateways|connections' })
  if ($gw.Count -eq 0) { Add-Finding 'NET-10' 'estate' "topology: $(if ($topology.Count) { "$($topology.Count) network resource(s), none is a circuit/gateway/connection" } else { 'not captured (Resource Graph unavailable) - verify manually' })" }
  $rsv = @($topology | Where-Object { ([string](Get-Prop $_ 'type' '')) -match 'dnsResolvers$' })
  if ($rsv.Count -eq 0) { Add-Finding 'NET-11' 'estate' "topology: DNS Private Resolvers=0$(if (-not $topology.Count) { ' (topology not captured - verify manually)' })" }
}
foreach ($pe in $pes) { $p = $pe.privateEndpoint; $pres = "private endpoint $($p.name)"
  foreach ($c in @(@(Get-Prop $p.properties 'privateLinkServiceConnections' @()) + @(Get-Prop $p.properties 'manualPrivateLinkServiceConnections' @()))) { $st = Get-Prop (Get-Prop $c.properties 'privateLinkServiceConnectionState') 'status' ''; if ($st -and $st -ne 'Approved') { Add-Finding 'NET-03' $pres "$(Leaf (Get-Prop $c.properties 'privateLinkServiceId' '')) status=$st" } }
  if (@($pe.privateDnsZoneGroups).Count -eq 0) { Add-Finding 'NET-04' $pres 'privateDnsZoneGroups=0' }
  $wantZone = if (([string](Get-Prop (Get-Prop @(Get-Prop $p.properties 'privateLinkServiceConnections' @())[0] 'properties') 'privateLinkServiceId' '')) -match 'StorageSync') { 'privatelink.afs.' } else { 'privatelink.file.' }
  $ok = $false
  foreach ($z in $zones) { if ($z.zone.name -like "*$wantZone*" -and @($z.virtualNetworkLinks).Count -gt 0 -and @($z.aRecords).Count -gt 0) { $ok = $true } }
  if (-not $ok) { Add-Finding 'NET-02' $pres "no $wantZone* zone with a VNet link and A records in the export" }
}

# -- 5. Server bundles ------------------------------------------------------------------------
foreach ($hn in $serverBundles.Keys) { $b = $serverBundles[$hn]; $res = "server $($b.hostname)"
  $svcs = @(Get-Prop $b.services 'services' @()); $fss = $svcs | Where-Object { $_.Name -eq 'FileSyncSvc' } | Select-Object -First 1
  $fdp = Get-Prop $b.services 'filterDriversPresent'
  if ((-not $fss) -or ([string](Get-Prop $fss 'Status' '') -notin @('Running', '4')) -or ((Get-Prop $fdp 'StorageSync' $true) -eq $false) -or ((Get-Prop $fdp 'StorageSyncGuard' $true) -eq $false)) { Add-Finding 'SRV-01' $res "FileSyncSvc=$(if ($fss) { Get-Prop $fss 'Status' '' } else { 'absent' }) filters: StorageSync=$(Get-Prop $fdp 'StorageSync' '?') Guard=$(Get-Prop $fdp 'StorageSyncGuard' '?')" }
  $mySe = @(); foreach ($s in $syncServices) { foreach ($se in $s.serverEndpoints) { $sn = ([string](Get-Prop $se.properties 'serverName' (Get-Prop $se.properties 'friendlyName' ''))).Split('.')[0]; if ($sn -ieq $b.hostname) { $mySe += $se } } }
  $tiered = @($mySe | Where-Object { ([string](Get-Prop $_.properties 'cloudTiering' 'off')) -ieq 'on' })
  $prods = @(Get-Prop $b.programs 'backupOrAvProducts' @())
  if ($tiered.Count -gt 0 -and $prods.Count -gt 0) { Add-Finding 'SRV-02' $res "products: $(($prods | ForEach-Object { $_.DisplayName }) -join ', ') ; tiered endpoints=$($tiered.Count)" }
  foreach ($se in $tiered) { $path = [string](Get-Prop $se.properties 'serverLocalPath' ''); $drive = $path.Substring(0, [math]::Min(2, $path.Length)).ToUpper(); $vol = @(Get-Prop $b.volumes 'volumes' @()) | Where-Object { ([string]$_.drive).ToUpper() -eq $drive } | Select-Object -First 1
    if ($vol) { $fp = [double](Get-Prop $vol 'freePercent' 100); $vfs = [double](Get-Prop $se.properties 'volumeFreeSpacePercent' 20); if ($fp -le ($vfs + 5)) { Add-Finding 'SRV-03' "$res $path" "free=$fp % policy=$vfs %" }
      $cl = Get-Prop $vol 'bytesPerCluster'; if ($cl -and [int]$cl -ge 65536) { Add-Finding 'SRV-09' "$res $drive" "bytesPerCluster=$cl" } }
  }
  $ws = $svcs | Where-Object { $_.Name -eq 'WSearch' -and ([string]$_.Status) -in @('Running', '4') }
  $feat = @(Get-Prop $b.volumes 'features' @()); $dfsr = $feat | Where-Object { $_.Name -eq 'FS-DFS-Replication' -and $_.Installed -eq $true }
  if (($ws -and $mySe.Count -gt 0) -or $dfsr) { Add-Finding 'SRV-04' $res "WSearch=$(if ($ws) { 'Running' } else { 'stopped' }) DFSR installed=$(if ($dfsr) { 'yes' } else { 'no' })" }
  $off = if ($b.w32tm -match 'Phase Offset:\s*(-?[\d.]+)s') { [math]::Abs([double]$Matches[1]) } else { $null }
  if (($off -ne $null -and $off -gt 300) -or ($b.w32tm -match 'Local CMOS Clock')) { Add-Finding 'SRV-05' $res "w32tm phase offset=$off s; source=$(if ($b.w32tm -match 'Source:\s*(.+)') { $Matches[1].Trim() } else { '?' })" }
  $bad = @($b.digest | Where-Object { $h = [string](Get-Prop $_ 'hresult' '0'); $h -ne '0' -and $h -ne '0x0' -and $h -ne '' })
  $pie = @($b.telemetry | Where-Object { $_.id -eq 9121 }).Count
  if ($bad.Count -ge 3 -or $pie -gt 0) { Add-Finding 'SRV-06' $res "9102 sessions with HResult!=0: $($bad.Count); 9121 per-item error events: $pie" }
  foreach ($r in @($b.ssr)) { if ([string](Get-Prop $r 'result' '') -match 'False|Disabled|not enabled') { $dl = [string](Get-Prop $r 'drive' ''); if (@($tiered | Where-Object { ([string](Get-Prop $_.properties 'serverLocalPath' '')).ToUpper().StartsWith($dl.ToUpper()) }).Count -gt 0) { Add-Finding 'SRV-07' "$res $dl" (Get-Prop $r 'result' '') } } }
  if (($b.diagnose -match '(?im)\b(fail|error)') -or ($b.network -match '(?im)\b(fail|error)')) { Add-Finding 'SRV-08' $res 'Debug-StorageSyncServer output contains Fail/Error - see debug-diagnose.txt / debug-network.txt' }
  $localVer = [string](Get-Prop $b.system 'agentFileVersion' (Get-Prop (Get-Prop $b.system 'agentProduct') 'DisplayVersion' ''))
  foreach ($s in $syncServices) { foreach ($srv in $s.servers) { $n = ([string](Get-Prop $srv.properties 'friendlyName' (Get-Prop $srv.properties 'serverName' ''))).Split('.')[0]; if ($n -ieq $b.hostname) { $cv = [string](Get-Prop $srv.properties 'agentVersion' ''); if ($localVer -and $cv -and ($localVer -ne $cv)) { Add-Finding 'SRV-10' $res "server=$localVer registered=$cv" } } } }
  foreach ($dv in @(Get-Prop $b.volumes 'dedup' @())) { if ((Get-Prop $dv 'Enabled' $false) -eq $true) { Add-Finding 'SRV-11' "$res $(Get-Prop $dv 'Volume' '')" "dedup enabled, MinimumFileAgeDays=$(Get-Prop $dv 'MinimumFileAgeDays' '')" } }
}
if ($exportErrors.Count -gt 0) { Add-Finding 'OPS-02' 'export' "$($exportErrors.Count) failed call(s): $((($exportErrors | Select-Object -First 8) | ForEach-Object { "$($_.where) -> $($_.detail)" }) -join ' | ')" }

# =========================================================================================
# REPORT
# =========================================================================================
$order = @{ High = 0; Medium = 1; Low = 2; Info = 3 }
$sorted = @($Findings | Sort-Object @{ e = { $order[$_.severity] } }, id, resource)
$counts = [ordered]@{ High = 0; Medium = 0; Low = 0; Info = 0 }; foreach ($f in $sorted) { $counts[$f.severity]++ }
$c = $manifest.counts
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Azure File Sync + Azure Backup assessment - $CustomerName")
[void]$md.Add('')
[void]$md.Add("- Export: $($exportedAt.ToString('u')) by $(Get-Prop $manifest 'exportedBy' '?') (tool v$(Get-Prop $manifest 'toolVersion' '?')); assessed $((Get-Date).ToUniversalTime().ToString('u')) with Assess v$ToolVersion")
[void]$md.Add("- Subscriptions: " + ((@(Get-Prop $manifest 'subscriptions' @()) | ForEach-Object { "$($_.name) (``$($_.id)``)" }) -join ', '))
[void]$md.Add("- Scope: $(Get-Prop $c 'storageSyncServices' 0) Storage Sync Service(s), $(Get-Prop $c 'syncGroups' 0) sync group(s), $(Get-Prop $c 'cloudEndpoints' 0) cloud + $(Get-Prop $c 'serverEndpoints' 0) server endpoint(s), $(Get-Prop $c 'registeredServers' 0) registered server(s), $(Get-Prop $c 'storageAccounts' 0) storage account(s) with $(Get-Prop $c 'fileShares' 0) file share(s), $(Get-Prop $c 'recoveryServicesVaults' 0) Recovery Services vault(s) / $(Get-Prop $c 'protectedItems' 0) protected item(s), $($serverBundles.Count) server bundle(s)")
[void]$md.Add('')
[void]$md.Add('## Scorecard')
[void]$md.Add('')
[void]$md.Add('| Severity | Findings |'); [void]$md.Add('|---|---|')
foreach ($k in $counts.Keys) { [void]$md.Add("| $k | $($counts[$k]) |") }
[void]$md.Add('')
[void]$md.Add('| Area | High | Medium | Low | Info |'); [void]$md.Add('|---|---|---|---|---|')
foreach ($area in @($sorted | ForEach-Object { $_.area } | Select-Object -Unique | Sort-Object)) { $g = @($sorted | Where-Object { $_.area -eq $area }); [void]$md.Add("| $area | $(@($g | Where-Object { $_.severity -eq 'High' }).Count) | $(@($g | Where-Object { $_.severity -eq 'Medium' }).Count) | $(@($g | Where-Object { $_.severity -eq 'Low' }).Count) | $(@($g | Where-Object { $_.severity -eq 'Info' }).Count) |") }
[void]$md.Add('')
foreach ($sev in @('High', 'Medium', 'Low', 'Info')) {
  $g = @($sorted | Where-Object { $_.severity -eq $sev }); if ($g.Count -eq 0) { continue }
  [void]$md.Add("## $sev findings ($($g.Count))"); [void]$md.Add('')
  [void]$md.Add('| ID | Resource | Finding | Evidence | Recommendation |'); [void]$md.Add('|---|---|---|---|---|')
  foreach ($f in $g) { [void]$md.Add("| $($f.id) | $($f.resource -replace '\|', '/') | $($f.title) | $($f.evidence -replace '\|', '/') | $($f.recommendation -replace '\|', '/') [ref]($($f.reference)) |") }
  [void]$md.Add('')
}
[void]$md.Add('## Recommendation roadmap'); [void]$md.Add('')
[void]$md.Add('### Do now (High)'); [void]$md.Add('')
foreach ($id in @($sorted | Where-Object { $_.severity -eq 'High' } | ForEach-Object { $_.id } | Select-Object -Unique)) { $r = $RuleById[$id]; $n = @($sorted | Where-Object { $_.id -eq $id }).Count; [void]$md.Add("- **$id $($r.Title)** ($n resource(s)) - $($r.Recommendation)") }
[void]$md.Add(''); [void]$md.Add('### This engagement window (Medium)'); [void]$md.Add('')
foreach ($id in @($sorted | Where-Object { $_.severity -eq 'Medium' } | ForEach-Object { $_.id } | Select-Object -Unique)) { $r = $RuleById[$id]; $n = @($sorted | Where-Object { $_.id -eq $id }).Count; [void]$md.Add("- **$id $($r.Title)** ($n resource(s)) - $($r.Recommendation)") }
[void]$md.Add(''); [void]$md.Add('### Backlog (Low)'); [void]$md.Add('')
foreach ($id in @($sorted | Where-Object { $_.severity -eq 'Low' } | ForEach-Object { $_.id } | Select-Object -Unique)) { $r = $RuleById[$id]; $n = @($sorted | Where-Object { $_.id -eq $id }).Count; [void]$md.Add("- **$id $($r.Title)** ($n resource(s)) - $($r.Recommendation)") }
[void]$md.Add('')
[void]$md.Add('## Assessment gaps'); [void]$md.Add('')
if ($exportErrors.Count -eq 0) { [void]$md.Add('- Export completed with no failed calls.') } else { foreach ($e in $exportErrors) { [void]$md.Add("- $($e.where): $($e.detail)") } }
$missing = @($sorted | Where-Object { $_.id -eq 'OPS-03' }); if ($missing.Count) { [void]$md.Add("- Server bundles missing for $($missing.Count) registered server(s) - server-side checks (SRV-*) were skipped for them.") }
[void]$md.Add('')
if ($IncludeCatalog) { [void]$md.Add('## Appendix - rule catalog'); [void]$md.Add(''); [void]$md.Add((Get-Catalog)) }

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$mdPath = Join-Path $OutputPath 'assessment.md'; $jsonPath = Join-Path $OutputPath 'findings.json'
[System.IO.File]::WriteAllText($mdPath, ($md -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($jsonPath, ([ordered]@{ tool = 'Assess-AzFileSyncExport.ps1'; toolVersion = $ToolVersion; customer = $CustomerName; export = $ExportPath; assessedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); counts = $counts; findings = $sorted } | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Findings: High={0} Medium={1} Low={2} Info={3} -> {4}" -f $counts.High, $counts.Medium, $counts.Low, $counts.Info, $mdPath)

# -- the HTML report: same findings, tabbed, self-contained, opens anywhere ----------------
# The export's summary.md (if the export was a folder or zip) goes on the Scope tab, and the
# rule catalog on the Rules tab when it was requested.
$htmlPath = Join-Path $OutputPath 'assessment.html'
try {
  . (Join-Path $PSScriptRoot 'Render-AfsAssessmentHtml.ps1')
  $summaryMd = $null
  foreach ($cand in @((Join-Path $root 'summary.md'), (Join-Path $OutputPath 'summary.md'))) {
    if ($cand -and (Test-Path $cand)) { $summaryMd = $cand; break }
  }
  $rulesMd = $null
  if ($IncludeCatalog) {
    $rulesMd = Join-Path $OutputPath 'rules.md'
    [System.IO.File]::WriteAllText($rulesMd, (Get-Catalog), (New-Object System.Text.UTF8Encoding($false)))
  }
  # $root is the resolved export (or the folder a zip was expanded into) - it is still on disk
  # at this point, so the subject tabs can render the estate itself, not just the findings.
  $null = ConvertTo-AfsAssessmentHtml -FindingsPath $jsonPath -OutputPath $htmlPath -SummaryPath $summaryMd -RulesPath $rulesMd -ExportRoot $root
  Write-Host ("Report: {0}" -f $htmlPath)
} catch {
  Write-Warning ("assessment.html was not produced: " + $_.Exception.Message)
}
if ($tempRoot -and (Test-Path $tempRoot)) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($PassThru) { $sorted }
