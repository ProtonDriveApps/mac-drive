// Copyright (c) 2023 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import Foundation
import PDClient

public class LocalSettings: NSObject {
    @SettingsStorage("computersInitialLoad") public var computersInitialLoad: Bool?
    @SettingsStorage("sortPreferenceCache") private var sortPreferenceCache: SortPreference.RawValue?
    @SettingsStorage("layoutPreferenceCache") private var layoutPreferenceCache: LayoutPreference.RawValue?
    @SettingsStorage("invitationSortPreference") private var invitationSortPreferenceCache: InvitationSortPreference.RawValue?
    @SettingsStorage("isUploadingDisclaimerActiveValue") private var isUploadingDisclaimerActiveValue: Bool?
    @SettingsStorage("isOnboarded") private var isOnboardedValue: Bool?
    @SettingsStorage("upsellShownValue") private var isUpsellShownValue: Bool?
    @SettingsStorage("isPhotoUpsellShownValue") private var isPhotoUpsellShownValue: Bool?
    @SettingsStorage("showPhotoUpsellInNextLaunch") public var showPhotoUpsellInNextLaunch: Bool?
    @SettingsStorage("didFetchFeatureFlags") public var didFetchFeatureFlags: Bool?

    @SettingsStorage("optOutFromTelemetry") var optOutFromTelemetry: Bool?
    @SettingsStorage("optOutFromCrashReports") var optOutFromCrashReports: Bool?
    @SettingsStorage("userId") public var userId: String?
    @SettingsStorage("isNoticationPermissionsSkipped") public var isNoticationPermissionsSkipped: Bool?
    @SettingsStorage("isPhotosBackupEnabledValue") private(set) var isPhotosBackupEnabledValue: Bool?
    @SettingsStorage("isPhotosBackupConnectionConstrainedValue") private(set) var isPhotosBackupConnectionConstrainedValue: Bool?
    @SettingsStorage("isPhotosNotificationsPermissionsSkipped") public var isPhotosNotificationsPermissionsSkipped: Bool?
    @SettingsStorage("isPhotosMediaTypeImageSupportedValue") private(set) var isPhotosMediaTypeImageSupportedValue: Bool?
    @SettingsStorage("isPhotosMediaTypeVideoSupportedValue") private(set) var isPhotosMediaTypeVideoSupportedValue: Bool?
    @SettingsStorage("isPhotoTagsAnalysisDisabledValue") private(set) var isPhotoTagsAnalysisDisabledValue: Bool?
    @SettingsStorage("photosBackupNotOlderThanValue") private(set) var photosBackupNotOlderThanValue: Date?
    @SettingsStorage("pushNotificationIsEnabled") private(set) var pushNotificationIsEnabledValue: Bool?
    @SettingsStorage("defaultHomeTabIndex") private(set) var defaultHomeTabTagValue: Int?
    @SettingsStorage("didShowPhotosNotification") public var didShowPhotosNotification: Bool?
    
    @SettingsStorage("photosUploadDisabled") public var photosUploadDisabledValue: Bool?
    @SettingsStorage("logsCompressionDisabledValue") public var logsCompressionDisabledValue: Bool?
    @SettingsStorage("domainReconnectionEnabledValue") public var domainReconnectionEnabledValue: Bool?
    @SettingsStorage("postMigrationJunkFilesCleanupValue") public var postMigrationJunkFilesCleanupValue: Bool?
    @SettingsStorage("newTrayAppMenuEnabledValue") public var newTrayAppMenuEnabledValue: Bool?
    @SettingsStorage("oneDollarPlanUpsellEnabledValue") public var oneDollarPlanUpsellEnabledValue: Bool?
    @SettingsStorage("promotedNewFeaturesValue") var promotedNewFeaturesValue: [String]?

    @SettingsStorage("DriveiOSLogCollection") public var driveiOSLogCollection: Bool?
    @SettingsStorage("debugModeEnabledValue") public var debugModeEnabledValue: Bool?
    @SettingsStorage("DriveiOSLogCollectionDisabled") public var driveiOSLogCollectionDisabled: Bool?
    @SettingsStorage("keepScreenAwakeBannerHasDismissed") public var keepScreenAwakeBannerHasDismissed: Bool?
    @SettingsStorage("DriveDDKEnabled") public var driveDDKEnabledValue: Bool?
    @SettingsStorage("DriveMacSyncRecoveryDisabled") public var driveMacSyncRecoveryDisabledValue: Bool?
    @SettingsStorage("DriveMacKeepDownloaded") public var driveMacKeepDownloadedValue: Bool?
    @SettingsStorage("DriveAlbumsDisabled") public var driveAlbumsDisabledValue: Bool?
    @SettingsStorage("DriveCopyDisabled") public var driveCopyDisabledValue: Bool?
    @SettingsStorage("photoVolumeMigrationLastShownDate") public var photoVolumeMigrationLastShownDate: Date?
    @SettingsStorage("QuotaState") public var quotaStateValue: Int?
    @SettingsStorage("domainVersion") public var domainVersionValue: Data?
    @SettingsStorage("DrivePhotosTagsMigration") public var drivePhotosTagsMigrationValue: Bool?
    @SettingsStorage("DrivePhotosTagsMigrationDisabled") public var drivePhotosTagsMigrationDisabledValue: Bool?

    @SettingsStorage("tagsMigrationFinished") public var tagsMigrationFinished: Bool?

    // Sharing flags
    @SettingsStorage("DriveSharingMigration") public var driveSharingMigrationValue: Bool?
    @SettingsStorage("DriveSharingInvitations") public var driveSharingInvitationsValue: Bool?
    @SettingsStorage("DriveSharingExternalInvitations") public var driveSharingExternalInvitationsValue: Bool?
    @SettingsStorage("DriveSharingDisabled") public var driveSharingDisabledValue: Bool?
    @SettingsStorage("DriveSharingExternalInvitationsDisabled") public var driveSharingExternalInvitationsDisabledValue: Bool?
    @SettingsStorage("DriveSharingEditingDisabled") public var driveSharingEditingDisabledValue: Bool?
    @SettingsStorage("DrivePublicShareEditMode") public var drivePublicShareEditModeValue: Bool?
    @SettingsStorage("DrivePublicShareEditModeDisabled") public var drivePublicShareEditModeDisabledValue: Bool?
    @SettingsStorage("DriveMobileSharingInvitationsAcceptReject") public var driveMobileSharingInvitationsAcceptRejectValue: Bool?
    @SettingsStorage("DriveShareURLBookmarking") public var driveShareURLBookmarkingValue: Bool?
    @SettingsStorage("DriveShareURLBookmarksDisabled") public var driveShareURLBookmarksDisabledValue: Bool?
    // Photo tab for b2b user
    @SettingsStorage("IsB2BUser") public var isB2BUser: Bool?
    /// Remote feature flag - DriveDisablePhotosForB2B
    @SettingsStorage("DriveDisablePhotosForB2B") public var driveDisablePhotosForB2BValue: Bool?
    
    // ProtonDoc
    @SettingsStorage("DriveDocsDisabled") private var driveDocsDisabledValue: Bool?
    
    // Entitlements
    @SettingsStorage("DriveDynamicEntitlementConfiguration") private var driveDynamicEntitlementConfigurationValue: Bool?
    @SettingsStorage("DriveEntitlements") public var driveEntitlementsValue: Data?
    @SettingsStorage("DriveEntitlementsUpdatedTime") public var driveEntitlementsUpdatedTimeValue: Int64?

    // Refactor
    @SettingsStorage("DriveiOSRefreshableBlockDownloadLink") private var driveiOSRefreshableBlockDownloadLinkValue: Bool?

    // Rating booster
    // Legacy feature flags we used before migrating to Unleash
    @SettingsStorage("RatingIOSDrive") private var ratingIOSDriveValue: Bool?
    @SettingsStorage("DriveRatingBooster") private var driveRatingBoosterValue: Bool?

    @SettingsStorage("didEnableComputers") public var didEnableComputersValue: Bool?
    @SettingsStorage("DriveiOSComputersValue") private var driveiOSComputersValue: Bool?
    @SettingsStorage("DriveiOSComputersDisabledValue") private var driveiOSComputersDisabledValue: Bool?

    // Checklist
    @SettingsStorage("driveChecklistStatusDataValue") private var driveChecklistStatusDataValue: Data?
    // ⚠️ Disclaimer: when adding new `@SettingsStorage` variable, make sure you configure its suite in initializer.

    @SettingsStorage("DocsSheetsEnabledValue") private var docsSheetsEnabledValue: Bool?
    @SettingsStorage("DocsSheetsDisabledValue") private var docsSheetsDisabledValue: Bool?
    @SettingsStorage("DocsCreateNewSheetOnMobileEnabledValue") private var docsCreateNewSheetOnMobileEnabledValue: Bool?

    @SettingsStorage("DriveiOSDebugMode") public var driveiOSDebugModeValue: Bool?

    public let suite: SettingsStorageSuite

    public init(suite: SettingsStorageSuite) {
        self.suite = suite
        super.init()
        self._computersInitialLoad.configure(with: suite)
        self._sortPreferenceCache.configure(with: suite)
        self._layoutPreferenceCache.configure(with: suite)
        self._invitationSortPreferenceCache.configure(with: suite)
        self._optOutFromTelemetry.configure(with: suite)
        self._optOutFromCrashReports.configure(with: suite)
        self._isOnboardedValue.configure(with: suite)
        self._isUpsellShownValue.configure(with: suite)
        self._isPhotoUpsellShownValue.configure(with: suite)
        self._showPhotoUpsellInNextLaunch.configure(with: suite)
        self._isUploadingDisclaimerActiveValue.configure(with: suite)
        self._isNoticationPermissionsSkipped.configure(with: suite)
        self._isPhotosBackupEnabledValue.configure(with: suite)
        self._isPhotosBackupConnectionConstrainedValue.configure(with: suite)
        self._isPhotosNotificationsPermissionsSkipped.configure(with: suite)
        self._isPhotosMediaTypeImageSupportedValue.configure(with: suite)
        self._isPhotosMediaTypeVideoSupportedValue.configure(with: suite)
        self._isPhotoTagsAnalysisDisabledValue.configure(with: suite)
        self._photosBackupNotOlderThanValue.configure(with: suite)
        self._photosUploadDisabledValue.configure(with: suite)
        self._logsCompressionDisabledValue.configure(with: suite)
        self._driveiOSLogCollection.configure(with: suite)
        self._debugModeEnabledValue.configure(with: suite)
        self._driveiOSLogCollectionDisabled.configure(with: suite)
        self._driveiOSDebugModeValue.configure(with: suite)
        self._domainReconnectionEnabledValue.configure(with: suite)
        self._postMigrationJunkFilesCleanupValue.configure(with: suite)
        self._newTrayAppMenuEnabledValue.configure(with: suite)
        self._userId.configure(with: suite)
        self._pushNotificationIsEnabledValue.configure(with: suite)
        self._defaultHomeTabTagValue.configure(with: suite)
        self._oneDollarPlanUpsellEnabledValue.configure(with: suite)
        self._keepScreenAwakeBannerHasDismissed.configure(with: suite)
        self._driveDDKEnabledValue.configure(with: suite)
        self._driveMacSyncRecoveryDisabledValue.configure(with: suite)
        self._driveMacKeepDownloadedValue.configure(with: suite)
        self._didFetchFeatureFlags.configure(with: suite)
        self._promotedNewFeaturesValue.configure(with: suite)
        self._driveAlbumsDisabledValue.configure(with: suite)
        self._driveCopyDisabledValue.configure(with: suite)
        self._photoVolumeMigrationLastShownDate.configure(with: suite)
        self._quotaStateValue.configure(with: suite)
        self._domainVersionValue.configure(with: suite)
        self._drivePhotosTagsMigrationValue.configure(with: suite)
        self._drivePhotosTagsMigrationDisabledValue.configure(with: suite)
        self._tagsMigrationFinished.configure(with: suite)

        // Sharing
        self._driveSharingMigrationValue.configure(with: suite)
        self._driveSharingInvitationsValue.configure(with: suite)
        self._driveSharingExternalInvitationsValue.configure(with: suite)
        self._driveSharingDisabledValue.configure(with: suite)
        self._driveSharingExternalInvitationsDisabledValue.configure(with: suite)
        self._driveSharingEditingDisabledValue.configure(with: suite)
        self._drivePublicShareEditModeValue.configure(with: suite)
        self._driveMobileSharingInvitationsAcceptRejectValue.configure(with: suite)
        self._driveShareURLBookmarkingValue.configure(with: suite)
        self._driveShareURLBookmarksDisabledValue.configure(with: suite)
        self._drivePublicShareEditModeDisabledValue.configure(with: suite)
        // Photo tab for b2b user
        self._isB2BUser.configure(with: suite)
        self._driveDisablePhotosForB2BValue.configure(with: suite)
        // ProtonDoc
        self._driveDocsDisabledValue.configure(with: suite)
        // Drive entitlements
        self._driveDynamicEntitlementConfigurationValue.configure(with: suite)
        self._driveEntitlementsValue.configure(with: suite)
        self._driveEntitlementsUpdatedTimeValue.configure(with: suite)
        // Rating booster
        // Legacy feature flags we used before migrating to Unleash
        self._ratingIOSDriveValue.configure(with: suite)
        self._driveRatingBoosterValue.configure(with: suite)

        // Computers
        self._didEnableComputersValue.configure(with: suite)
        self._driveiOSComputersValue.configure(with: suite)
        self._driveiOSComputersDisabledValue.configure(with: suite)

        // Refactor
        self._driveiOSRefreshableBlockDownloadLinkValue.configure(with: suite)

        if let sortPreferenceCache = self.sortPreferenceCache {
            nodesSortPreference = SortPreference(rawValue: sortPreferenceCache) ?? SortPreference.default
        } else {
            nodesSortPreference = SortPreference.default
        }
        self._driveChecklistStatusDataValue.configure(with: suite)
        self._docsSheetsEnabledValue.configure(with: suite)
        self._docsSheetsDisabledValue.configure(with: suite)
        self._docsCreateNewSheetOnMobileEnabledValue.configure(with: suite)
        setDynamicVariables()
    }
    
    /// KVO compliant dynamic variables need to be set inidividually after initialization / cleanup
    private func setDynamicVariables() {
        nodesLayoutPreference = LayoutPreference(cachedValue: layoutPreferenceCache)
        isUploadingDisclaimerActive = isUploadingDisclaimerActiveValue ?? true
        isPhotosBackupEnabled = isPhotosBackupEnabledValue ?? false
        isPhotosBackupConnectionConstrained = isPhotosBackupConnectionConstrainedValue ?? true
        isPhotosMediaTypeImageSupported = isPhotosMediaTypeImageSupportedValue ?? true
        isPhotosMediaTypeVideoSupported = isPhotosMediaTypeVideoSupportedValue ?? true
        isPhotoTagsAnalysisDisabled = isPhotoTagsAnalysisDisabledValue ?? false
        photosBackupNotOlderThan = photosBackupNotOlderThanValue ?? .distantPast
        photosUploadDisabled = photosUploadDisabledValue ?? false
        logsCompressionDisabled = logsCompressionDisabledValue ?? false
        logCollectionEnabled = driveiOSLogCollection ?? false
        logCollectionDisabled = driveiOSLogCollectionDisabled ?? false
        debugModeEnabled = debugModeEnabledValue ?? false
        domainReconnectionEnabled = domainReconnectionEnabledValue ?? false
        postMigrationJunkFilesCleanup = postMigrationJunkFilesCleanupValue ?? false
        newTrayAppMenuEnabled = newTrayAppMenuEnabledValue ?? false
        oneDollarPlanUpsellEnabled = oneDollarPlanUpsellEnabledValue ?? false
        isOnboarded = isOnboardedValue ?? false
        pushNotificationIsEnabled = pushNotificationIsEnabledValue ?? false
        if let value = defaultHomeTabTagValue {
            defaultHomeTabTag = value
        }
        driveSharingMigration = driveSharingMigrationValue ?? false
        driveSharingInvitations = driveSharingInvitationsValue ?? false
        driveSharingExternalInvitations = driveSharingExternalInvitationsValue ?? false
        driveSharingDisabled = driveSharingDisabledValue ?? false
        driveSharingExternalInvitationsDisabled = driveSharingExternalInvitationsDisabledValue ?? false
        driveSharingEditingDisabled = driveSharingEditingDisabledValue ?? false
        drivePublicShareEditMode = drivePublicShareEditModeValue ?? false
        driveMobileSharingInvitationsAcceptReject = driveMobileSharingInvitationsAcceptRejectValue ?? false
        driveShareURLBookmarking = driveShareURLBookmarkingValue ?? false
        driveShareURLBookmarksDisabled = driveShareURLBookmarksDisabledValue ?? false
        drivePublicShareEditModeDisabled = drivePublicShareEditModeDisabledValue ?? false
        driveDisablePhotosForB2B = driveDisablePhotosForB2BValue ?? false
        driveDocsDisabled = driveDocsDisabledValue ?? false
        driveDDKEnabled = driveDDKEnabledValue ?? false
        driveMacSyncRecoveryDisabled = driveMacSyncRecoveryDisabledValue ?? false
        driveMacKeepDownloaded = driveMacKeepDownloadedValue ?? false
        didEnableComputers = didEnableComputersValue ?? false
        driveiOSComputers = driveiOSComputersValue ?? false
        driveiOSComputersDisabled = driveiOSComputersDisabledValue ?? false
        docsSheetsEnabled = docsSheetsEnabledValue ?? false
        docsSheetsDisabled = docsSheetsDisabledValue ?? false
        docsCreateNewSheetOnMobileEnabled = docsCreateNewSheetOnMobileEnabledValue ?? false
    }

    /// `cleanUserSpecificSettings`
    ///     - true if we want to clean everything
    ///     - false if we want to keep flags related to the user
    ///     Used to differentiate signout and clean cache - signout should wipe everything,
    ///     clean cache only real "cache" item
    public func cleanUp(cleanUserSpecificSettings: Bool = true) {
        self.computersInitialLoad = nil
        self.sortPreferenceCache = nil
        self.layoutPreferenceCache = nil
        self.invitationSortPreferenceCache = nil
        self.optOutFromTelemetry = nil
        self.optOutFromCrashReports = nil
        self.userId = nil
        self.didFetchFeatureFlags = nil
        self.domainVersionValue = nil
        // self.isOnboardedValue needs no clean up - we only show it for first login ever
        // self.isUpsellShownValue needs no clean up - we only show it once
        // self.isPhotoUpsellShownValue needs no clean up - we only show it once
        // self.defaultHomeTabTagValue needs no clean up - we keep the setting for forever
        self.isUploadingDisclaimerActiveValue = nil
        self.isNoticationPermissionsSkipped = nil
        self.isPhotosBackupEnabledValue = nil
        self.isPhotosBackupConnectionConstrainedValue = nil
        self.isPhotosNotificationsPermissionsSkipped = nil
        self.isPhotosMediaTypeImageSupportedValue = nil
        self.isPhotosMediaTypeVideoSupportedValue = nil
        self.isPhotoTagsAnalysisDisabledValue = nil
        self.photosUploadDisabledValue = nil
        self.logsCompressionDisabledValue = nil
        self.debugModeEnabledValue = nil
        self.domainReconnectionEnabledValue = nil
        self.postMigrationJunkFilesCleanupValue = nil
        self.newTrayAppMenuEnabledValue = nil
        self.driveDDKEnabledValue = nil
        self.driveMacSyncRecoveryDisabledValue = nil
        self.driveMacKeepDownloadedValue = nil
        self.pushNotificationIsEnabledValue = nil
        self.keepScreenAwakeBannerHasDismissed = nil
        self.didShowPhotosNotification = nil
        self.isB2BUser = nil
        self.showPhotoUpsellInNextLaunch = nil
        self.driveDisablePhotosForB2BValue = nil
        self.driveSharingMigrationValue = nil
        self.driveSharingInvitationsValue = nil
        self.driveSharingExternalInvitationsValue = nil
        self.driveSharingDisabledValue = nil
        self.driveSharingExternalInvitationsDisabledValue = nil
        self.driveSharingEditingDisabledValue = nil
        self.drivePublicShareEditModeValue = nil
        self.driveMobileSharingInvitationsAcceptRejectValue = nil
        self.driveShareURLBookmarkingValue = nil
        self.driveShareURLBookmarksDisabledValue = nil
        self.drivePublicShareEditModeDisabledValue = nil
        self.driveDynamicEntitlementConfigurationValue = nil
        self.driveEntitlementsValue = nil
        self.driveEntitlementsUpdatedTimeValue = nil
        self.ratingIOSDriveValue = nil
        self.driveRatingBoosterValue = nil
        self.driveiOSRefreshableBlockDownloadLinkValue = nil
        self.didEnableComputersValue = nil
        self.driveiOSComputersValue = nil
        self.driveiOSComputersDisabledValue = nil
        self.driveiOSDebugModeValue = nil
        if cleanUserSpecificSettings {
            promotedNewFeaturesValue = nil
            quotaStateValue = nil
        }
        driveAlbumsDisabledValue = nil
        driveCopyDisabledValue = nil
        photoVolumeMigrationLastShownDate = nil
        driveChecklistStatusDataValue = nil
        drivePhotosTagsMigrationValue = nil
        drivePhotosTagsMigrationDisabledValue = nil
        tagsMigrationFinished = nil
        setDynamicVariables()
    }
    
    @objc public dynamic var nodesSortPreference: SortPreference = SortPreference.default {
        willSet {
            self.sortPreferenceCache = newValue.rawValue
        }
    }
    
    @objc public dynamic var nodesLayoutPreference: LayoutPreference = LayoutPreference.default {
        willSet {
            self.layoutPreferenceCache = newValue.rawValue
        }
    }

    @objc public dynamic var invitationSortPreference: InvitationSortPreference = InvitationSortPreference.default {
        willSet {
            self.invitationSortPreferenceCache = newValue.rawValue
        }
    }

    @objc public dynamic var isUploadingDisclaimerActive: Bool = true {
        willSet {
            isUploadingDisclaimerActiveValue = newValue
        }
    }
    
    @objc public dynamic var isPhotosBackupEnabled: Bool = false {
        willSet {
            isPhotosBackupEnabledValue = newValue
        }
    }
    
    @objc public dynamic var isPhotosBackupConnectionConstrained: Bool = true {
        willSet {
            isPhotosBackupConnectionConstrainedValue = newValue
        }
    }
    
    @objc public dynamic var isPhotosMediaTypeImageSupported: Bool = true {
        willSet {
            isPhotosMediaTypeImageSupportedValue = newValue
        }
    }
    
    @objc public dynamic var isPhotosMediaTypeVideoSupported: Bool = true {
        willSet {
            isPhotosMediaTypeVideoSupportedValue = newValue
        }
    }

    @objc public dynamic var isPhotoTagsAnalysisDisabled: Bool = false {
        willSet {
            isPhotoTagsAnalysisDisabledValue = newValue
        }
    }

    @objc public dynamic var photosBackupNotOlderThan: Date = .distantPast {
        willSet {
            photosBackupNotOlderThanValue = newValue
        }
    }
    
    @objc public dynamic var photosUploadDisabled: Bool = false {
        willSet {
            photosUploadDisabledValue = newValue
        }
    }
    
    @objc public dynamic var logsCompressionDisabled: Bool = false {
        willSet {
            logsCompressionDisabledValue = newValue
        }
    }
    
    @objc public dynamic var domainReconnectionEnabled: Bool = false {
        willSet {
            domainReconnectionEnabledValue = newValue
        }
    }
    
    @objc public dynamic var postMigrationJunkFilesCleanup: Bool = false {
        willSet {
            postMigrationJunkFilesCleanupValue = newValue
        }
    }
    
    @objc public dynamic var newTrayAppMenuEnabled: Bool = false {
        willSet {
            newTrayAppMenuEnabledValue = newValue
        }
    }
    
    @objc public dynamic var oneDollarPlanUpsellEnabled: Bool = false {
        willSet {
            oneDollarPlanUpsellEnabledValue = newValue
        }
    }
    
    @objc public dynamic var isOnboarded: Bool = false {
        willSet {
            isOnboardedValue = newValue ? true : nil
        }
    }
    
    @objc public dynamic var pushNotificationIsEnabled: Bool = false {
        willSet {
            pushNotificationIsEnabledValue = newValue
        }
    }
    
    @objc public dynamic var logCollectionEnabled: Bool = false {
        willSet {
            driveiOSLogCollection = newValue
        }
    }
    
    @objc public dynamic var logCollectionDisabled: Bool = false {
        willSet {
            driveiOSLogCollectionDisabled = newValue
        }
    }

    public var driveiOSDebugMode: Bool {
        get { driveiOSDebugModeValue ?? false }
        set { driveiOSDebugModeValue = newValue }
    }

    @objc public dynamic var defaultHomeTabTag: Int = 1 {
        willSet {
            defaultHomeTabTagValue = newValue
        }
    }
    
    @objc public dynamic var isUpsellShown: Bool {
        get { isUpsellShownValue == true }
        set { isUpsellShownValue = (newValue ? true : nil) }
    }

    @objc public dynamic var debugModeEnabled: Bool = false {
        willSet {
            debugModeEnabledValue = newValue
        }
    }

    public var promotedNewFeatures: [String] {
        promotedNewFeaturesValue ?? []
    }
    
    public func append(promotedNewFeatures: [String]) {
        let features = promotedNewFeaturesValue ?? []
        promotedNewFeaturesValue = Array(Set(features.appending(promotedNewFeatures)))
    }

    // MARK: - Sharing
    @objc public dynamic var driveSharingMigration: Bool = false {
        willSet { driveSharingMigrationValue = newValue }
    }
    
    @objc public dynamic var driveSharingInvitations: Bool = false {
        willSet { driveSharingInvitationsValue = newValue }
    }
    
    @objc public dynamic var driveSharingExternalInvitations: Bool = false {
        willSet { driveSharingExternalInvitationsValue = newValue }
    }
    
    @objc public dynamic var driveSharingDisabled: Bool = false {
        willSet { driveSharingDisabledValue = newValue }
    }
    
    @objc public dynamic var driveSharingExternalInvitationsDisabled: Bool = false {
        willSet { driveSharingExternalInvitationsDisabledValue = newValue }
    }
    
    @objc public dynamic var driveSharingEditingDisabled: Bool = false {
        willSet { driveSharingEditingDisabledValue = newValue }
    }
    
    @objc public dynamic var drivePublicShareEditMode: Bool = false {
        willSet { drivePublicShareEditModeValue = newValue }
    }

    @objc public dynamic var driveMobileSharingInvitationsAcceptReject: Bool = false {
        willSet { driveMobileSharingInvitationsAcceptRejectValue = newValue }
    }

    @objc public dynamic var driveShareURLBookmarking: Bool = false {
        willSet { driveShareURLBookmarkingValue = newValue }
    }

    @objc public dynamic var driveShareURLBookmarksDisabled: Bool = false {
        willSet { driveShareURLBookmarksDisabledValue = newValue }
    }

    @objc public dynamic var drivePublicShareEditModeDisabled: Bool = false {
        willSet { drivePublicShareEditModeDisabledValue = newValue }
    }

    public var isPhotoUpsellShown: Bool {
        get { isPhotoUpsellShownValue ?? false }
        set { isPhotoUpsellShownValue = (newValue ? true : nil) }
    }
    
    @objc public dynamic var driveDisablePhotosForB2B: Bool = false {
        willSet { driveDisablePhotosForB2BValue = newValue }
    }
    
    public var driveDocsDisabled: Bool = false {
        willSet { driveDocsDisabledValue = newValue }
    }
    
    public var driveDDKEnabled: Bool {
        get { driveDDKEnabledValue ?? false }
        set { driveDDKEnabledValue = newValue }
    }
    
    public var driveMacSyncRecoveryDisabled: Bool {
        get { driveMacSyncRecoveryDisabledValue ?? false }
        set { driveMacSyncRecoveryDisabledValue = newValue }
    }

    public var driveMacKeepDownloaded: Bool {
        get { driveMacKeepDownloadedValue ?? false }
        set { driveMacKeepDownloadedValue = newValue }
    }

    public var ratingIOSDrive: Bool {
        get { ratingIOSDriveValue ?? false }
        set { ratingIOSDriveValue = newValue }
    }
    
    public var driveRatingBooster: Bool {
        get { driveRatingBoosterValue ?? false }
        set { driveRatingBoosterValue = newValue }
    }

    public var driveDynamicEntitlementConfiguration: Bool {
        get { driveDynamicEntitlementConfigurationValue ?? false }
        set { driveDynamicEntitlementConfigurationValue = newValue }
    }

    public var driveiOSRefreshableBlockDownloadLink: Bool {
        get { driveiOSRefreshableBlockDownloadLinkValue ?? false }
        set { driveiOSRefreshableBlockDownloadLinkValue = newValue }
    }

    public var driveAlbumsDisabled: Bool {
        get { driveAlbumsDisabledValue ?? false }
        set { driveAlbumsDisabledValue = newValue }
    }

    public var driveCopyDisabled: Bool {
        get { driveCopyDisabledValue ?? false }
        set { driveCopyDisabledValue = newValue }
    }

    public var driveiOSComputers: Bool {
        get { driveiOSComputersValue ?? false }
        set { driveiOSComputersValue = newValue }
    }

    public var driveiOSComputersDisabled: Bool {
        get { driveiOSComputersDisabledValue ?? false }
        set { driveiOSComputersDisabledValue = newValue }
    }

    public var didEnableComputers: Bool {
        get { didEnableComputersValue ?? false }
        set { didEnableComputersValue = newValue }
    }

    // If there is no data about the checklist status, return empty data that will be interpreted as not available.
    @objc public dynamic var driveChecklistStatusData: Data {
        get { driveChecklistStatusDataValue ?? Data() }
        set { driveChecklistStatusDataValue = newValue }
    }

    public var drivePhotosTagsMigration: Bool {
        get { drivePhotosTagsMigrationValue ?? false }
        set { drivePhotosTagsMigrationValue = newValue }
    }

    public var drivePhotosTagsMigrationDisabled: Bool {
        get { drivePhotosTagsMigrationDisabledValue ?? false }
        set { drivePhotosTagsMigrationDisabledValue = newValue }
    }

    public var docsSheetsEnabled: Bool {
        get { docsSheetsEnabledValue ?? false }
        set { docsSheetsEnabledValue = newValue }
    }

    public var docsSheetsDisabled: Bool {
        get { docsSheetsDisabledValue ?? false }
        set { docsSheetsDisabledValue = newValue }
    }

    public var docsCreateNewSheetOnMobileEnabled: Bool {
        get { docsCreateNewSheetOnMobileEnabledValue ?? false }
        set { docsCreateNewSheetOnMobileEnabledValue = newValue }
    }
}

#if DEBUG
extension LocalSettings {
    public func clearDefaultHomeTab() {
        defaultHomeTabTagValue = nil
    }
    
    public func clearPromotedNewFeatures() {
        promotedNewFeaturesValue = nil
    }
}
#endif

public extension LocalSettings {
    // Please do not create new instances of this class. Use the shared instance instead.
    static let shared = LocalSettings(suite: .group(named: Constants.appGroup))
}
