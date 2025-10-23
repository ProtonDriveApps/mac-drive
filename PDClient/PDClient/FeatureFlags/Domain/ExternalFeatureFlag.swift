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

public enum ExternalFeatureFlag: String, CaseIterable, Codable {
    case photosUploadDisabled = "DrivePhotosUploadDisabled"
    case logsCompressionDisabled = "DriveLogsCompressionDisabled"
    case domainReconnectionEnabled = "DriveDomainReconnectionEnabled"
    case postMigrationJunkFilesCleanup = "DrivePostMigrationJunkFilesCleanup"
    case pushNotificationIsEnabled = "PushNotifications"
    case logCollectionEnabled = "DriveiOSLogCollection"
    case logCollectionDisabled = "DriveiOSLogCollectionDisabled"
    case driveiOSDebugMode = "DriveiOSDebugMode"
    case oneDollarPlanUpsellEnabled = "DriveOneDollarPlanUpsell"
    case driveDisablePhotosForB2B = "DriveDisablePhotosForB2B"
    case driveDDKIntelEnabled = "DriveDDKIntelEnabled"
    case driveDDKDisabled = "DriveDDKDisabled"
    case driveMacSyncRecoveryDisabled = "DriveMacSyncRecoveryDisabled"
    case driveMacKeepDownloadedDisabled = "DriveMacKeepDownloadedDisabled"

    // Sharing
    case driveSharingMigration = "DriveSharingMigration"
    case driveSharingInvitations = "DriveSharingInvitations"
    case driveSharingExternalInvitations = "DriveSharingExternalInvitations"
    case driveSharingDisabled = "DriveSharingDisabled"
    case driveSharingExternalInvitationsDisabled = "DriveSharingExternalInvitationsDisabled"
    case driveSharingEditingDisabled = "DriveSharingEditingDisabled"
    case drivePublicShareEditMode = "DrivePublicShareEditMode"
    case drivePublicShareEditModeDisabled = "DrivePublicShareEditModeDisabled"
    case acceptRejectInvitation = "DriveMobileSharingInvitationsAcceptReject"
    case driveShareURLBookmarking = "DriveShareURLBookmarking"
    case driveShareURLBookmarksDisabled = "DriveShareURLBookmarksDisabled"

    // ProtonDoc
    case driveDocsDisabled = "DriveDocsDisabled"

    // Rating booster
    // Legacy feature flags we used before migrating to Unleash
    case ratingIOSDrive = "RatingIOSDrive"
    case driveRatingBooster = "DriveRatingBooster"

    // Entitlement
    case driveDynamicEntitlementConfiguration = "DriveDynamicEntitlementConfiguration"

    // Refactor
    case driveiOSRefreshableBlockDownloadLink = "DriveiOSRefreshableBlockDownloadLink"

    // Computers
    case driveiOSComputers = "DriveiOSComputers"
    case driveiOSComputersDisabled = "DriveiOSComputersDisabled"

    // Albums
    case driveAlbumsDisabled = "DriveAlbumsDisabled"
    case driveCopyDisabled = "DriveCopyDisabled"
    case drivePhotosTagsMigration = "DrivePhotosTagsMigration"
    case drivePhotosTagsMigrationDisabled = "DrivePhotosTagsMigrationDisabled"

    // Sheets
    case docsSheetsEnabled = "DocsSheetsEnabled"
    case docsSheetsDisabled = "DocsSheetsDisabled"
    case docsCreateNewSheetOnMobileEnabled = "DocsCreateNewSheetOnMobileEnabled"

    // Payments
    case driveiOSPaymentsV2 = "DriveiOSPaymentsV2"

    // SDK
    case driveiOSSDKUploadMain = "DriveiOSSDKUploadMain"
    case driveiOSSDKUploadPhoto = "DriveiOSSDKUploadPhoto"
    case driveiOSSDKDownloadMain = "DriveiOSSDKDownloadMain"
    case driveiOSSDKDownloadPhoto = "DriveiOSSDKDownloadPhoto"

    // Black Friday 2025
    case driveIOSBlackFriday2025 = "DriveIOSBlackFriday2025"
}
