// Copyright (c) 2024 Proton AG
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

#if os(macOS)

import Foundation

// The list comes from `PDLocalization/Resources/Localizable.xcstrings`
// We enable languages that have been translated for over 95%.
enum SupportedLanguage: String, CaseIterable {
    case english = "en"
    // case belarusian = "be"
    // case catalan = "ca"
    // case czech = "cs"
    // case danish = "da"
    // case dutch = "nl"
    // case finnish = "fi"
    // case french = "fr"
    // case georgian = "ka"
    // case german = "de"
    // case greek = "el"
    // case indonesian = "id"
    // case italian = "it"
    // case japanese = "ja"
    // case korean = "ko"
    // case norwegianBokmål = "nb"
    // case polish = "pl"
    // case portuguese = "pt"
    // case romanian = "ro"
    // case russian = "ru"
    // case slovak = "sk"
    // case spanish = "es"
    // case spanishLatinAmerican = "es-419"
    // case swedish = "sv"
    // case turkish = "tr"
    // case ukrainian = "uk"
}

public class Localization {
    public static var isUITest = false
    public static var bundlePreferredLocalization: String? { Bundle.main.preferredLocalizations.first }
    private static let defaultLanguage = "en"
    private static let availableLanguages = SupportedLanguage.allCases.map { $0.rawValue }
    private static let preferredLanguages: [String] = {
        let preferredLanguages = Locale.preferredLanguages.map { languageCode in
            let component = Locale.Components(identifier: languageCode)
            guard let identifier = component.languageComponents.languageCode?.identifier else {
                return languageCode
            }
            if let script = component.languageComponents.script?.identifier {
                return identifier + "-" + script
            } else {
                return identifier
            }
        }
        
        return preferredLanguages
    }()
    
    private static let bundle: Bundle = {
        /* Until the reason of the localization bug is reproduced, allow only English in the app.  
        let main: Bundle = .module
        for language in preferredLanguages {
            guard
                availableLanguages.contains(language),
                let path = main.path(forResource: language, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else { continue }
            return bundle
        }
        */
        return enBundle
    }()
    
    private static let enBundle: Bundle = {
        let main: Bundle = .module
        guard
            let path = main.path(forResource: defaultLanguage, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return main }
        return bundle
    }()
    
    static func localized(key: String, table: String) -> String {
        let str = String(localized: .init(key), table: table, bundle: bundle)
        if str == key {
            return String(localized: .init(key), table: table, bundle: enBundle)
        } else {
            return str
        }
    }
    /// "Shown directly after resuming, while FileProvider is determining whether there are changes to sync."
    /// "Looking for files to sync…"
    public static var enumerating_after_resuming: String { localized(key: "enumerating_after_resuming", table: "Mac-Localizable") }

    /// "Banner shown after an automatic refresh of the file list finishes."
    /// "Your file list is up to date"
    public static var full_resync_auto_completed: String { localized(key: "full_resync_auto_completed", table: "Mac-Localizable") }

    /// "Status row in the menu bar dropdown while updates are applied during an automatic refresh of the file list."
    /// "Refreshing your file list (step 2 of 2)…"
    public static var full_resync_auto_status_applying: String { localized(key: "full_resync_auto_status_applying", table: "Mac-Localizable") }

    /// "Status row in the menu bar dropdown while file information is downloaded during an automatic refresh of the file list."
    /// "Refreshing your file list (step 1 of 2)…"
    public static var full_resync_auto_status_downloading: String { localized(key: "full_resync_auto_status_downloading", table: "Mac-Localizable") }

    /// "Status row in the menu bar dropdown when an automatic refresh of the file list is paused. The number is how many files were processed so far."
    /// "Refresh paused — %d files so far"
    public static func full_resync_auto_status_paused(itemsProcessed: Int) -> String { String(format: localized(key: "full_resync_auto_status_paused", table: "Mac-Localizable"), itemsProcessed) }

    /// "Title in the tray window while Proton Drive refreshes its file list because the server reported the local one is out of date. Not started by the user."
    /// "Refreshing your file list"
    public static var full_resync_auto_title: String { localized(key: "full_resync_auto_title", table: "Mac-Localizable") }

    /// "Cancel resync"
    public static var full_resync_cancel_confirm_action: String { localized(key: "full_resync_cancel_confirm_action", table: "Mac-Localizable") }

    /// "Are you sure you want to cancel? You will lose the progress you have so far."
    public static var full_resync_cancel_confirm_body: String { localized(key: "full_resync_cancel_confirm_body", table: "Mac-Localizable") }

    /// "Cancel resync"
    public static var full_resync_cancel_confirm_title: String { localized(key: "full_resync_cancel_confirm_title", table: "Mac-Localizable") }

    /// "Resync was cancelled before it finished. Retry, or create a new sync folder."
    public static var full_resync_cancelled_recovery: String { localized(key: "full_resync_cancelled_recovery", table: "Mac-Localizable") }

    /// "Pre-resync confirmation dialog action button"
    /// "Resync"
    public static var full_resync_confirm_action: String { localized(key: "full_resync_confirm_action", table: "Mac-Localizable") }

    /// "Pre-resync confirmation dialog body"
    /// "Resyncing may take some time, depending on how many files you have."
    public static var full_resync_confirm_body: String { localized(key: "full_resync_confirm_body", table: "Mac-Localizable") }

    /// "Pre-resync confirmation dialog title"
    /// "Resync your Drive?"
    public static var full_resync_confirm_title: String { localized(key: "full_resync_confirm_title", table: "Mac-Localizable") }

    /// "Continue resyncing"
    public static var full_resync_continue: String { localized(key: "full_resync_continue", table: "Mac-Localizable") }

    /// "Confirmation dialog body before rebuilding the local sync folder"
    /// "Proton Drive will be set up again on this Mac. The previous copy on this Mac will remain unchanged."
    public static var full_resync_create_new_confirm_body: String { localized(key: "full_resync_create_new_confirm_body", table: "Mac-Localizable") }

    /// "Confirmation dialog title before rebuilding the local sync folder"
    /// "Create new sync folder"
    public static var full_resync_create_new_confirm_title: String { localized(key: "full_resync_create_new_confirm_title", table: "Mac-Localizable") }

    /// "Create new sync folder"
    public static var full_resync_create_new_location: String { localized(key: "full_resync_create_new_location", table: "Mac-Localizable") }

    /// "Dismiss"
    public static var full_resync_dismiss: String { localized(key: "full_resync_dismiss", table: "Mac-Localizable") }

    /// "You have completed the resync."
    public static var full_resync_finished: String { localized(key: "full_resync_finished", table: "Mac-Localizable") }

    /// "Resync brings your Mac up to date with Proton Drive. Use it if your files don\'t appear to be syncing correctly.\n\nDuring resync, Proton Drive checks your files and makes any needed changes on your Mac.\n\nYour files stay available, and you can keep using your Mac while resync runs."
    public static var full_resync_info_body: String { localized(key: "full_resync_info_body", table: "Mac-Localizable") }

    /// "Retry continues the resync from where it stopped.\n\nCreate a new sync folder rebuilds your local folder from scratch.\n\nCancel stops the resync and returns to normal syncing."
    public static var full_resync_info_error_body: String { localized(key: "full_resync_info_error_body", table: "Mac-Localizable") }

    /// "Resume continues the resync from where it stopped.\n\nCancel stops the resync and returns to normal syncing."
    public static var full_resync_info_paused_body: String { localized(key: "full_resync_info_paused_body", table: "Mac-Localizable") }

    /// "About resync"
    public static var full_resync_info_title: String { localized(key: "full_resync_info_title", table: "Mac-Localizable") }

    /// "%@ found"
    public static func full_resync_items_found(count: String) -> String { String(format: localized(key: "full_resync_items_found", table: "Mac-Localizable"), count) }

    /// "Learn more"
    public static var full_resync_learn_more: String { localized(key: "full_resync_learn_more", table: "Mac-Localizable") }

    /// "Pause"
    public static var full_resync_pause: String { localized(key: "full_resync_pause", table: "Mac-Localizable") }

    /// "%d%%"
    public static func full_resync_percent(percent: Int) -> String { String(format: localized(key: "full_resync_percent", table: "Mac-Localizable"), percent) }

    /// "Setting things up…"
    public static var full_resync_preparing: String { localized(key: "full_resync_preparing", table: "Mac-Localizable") }

    /// "Resume"
    public static var full_resync_resume: String { localized(key: "full_resync_resume", table: "Mac-Localizable") }

    /// "Hint shown during the resync phases that cannot be paused or cancelled"
    /// "You can safely leave this window during the resync"
    public static var full_resync_safe_to_leave: String { localized(key: "full_resync_safe_to_leave", table: "Mac-Localizable") }

    /// "Shown in Settings view"
    /// "Full resync"
    public static var full_resync_state_description: String { localized(key: "full_resync_state_description", table: "Mac-Localizable") }

    /// "Resync step label (idle/done): apply-updates phase"
    /// "Sync changes"
    public static var full_resync_step_apply: String { localized(key: "full_resync_step_apply", table: "Mac-Localizable") }

    /// "Syncing changes…"
    public static var full_resync_step_applying: String { localized(key: "full_resync_step_applying", table: "Mac-Localizable") }

    /// "Resync step label (idle/done): discovery phase"
    /// "Find your files"
    public static var full_resync_step_discover: String { localized(key: "full_resync_step_discover", table: "Mac-Localizable") }

    /// "Finding your files…"
    public static var full_resync_step_discovering: String { localized(key: "full_resync_step_discovering", table: "Mac-Localizable") }

    /// "Resync step label (idle/done): download phase"
    /// "Check what\'s changed"
    public static var full_resync_step_download: String { localized(key: "full_resync_step_download", table: "Mac-Localizable") }

    /// "Checking what\'s changed…"
    public static var full_resync_step_downloading: String { localized(key: "full_resync_step_downloading", table: "Mac-Localizable") }

    /// "Step %1$d: %2$@"
    public static func full_resync_step_label(number: Int, title: String) -> String { String(format: localized(key: "full_resync_step_label", table: "Mac-Localizable"), number, title) }

    /// "Resync step label (idle/done): refresh phase"
    /// "Finish up"
    public static var full_resync_step_refresh: String { localized(key: "full_resync_step_refresh", table: "Mac-Localizable") }

    /// "Finishing up…"
    public static var full_resync_step_refreshing: String { localized(key: "full_resync_step_refreshing", table: "Mac-Localizable") }

    /// "Resync in progress…"
    public static var full_resync_title: String { localized(key: "full_resync_title", table: "Mac-Localizable") }

    /// "Resync failed"
    public static var full_resync_title_failed: String { localized(key: "full_resync_title_failed", table: "Mac-Localizable") }

    /// "Resync paused"
    public static var full_resync_title_paused: String { localized(key: "full_resync_title_paused", table: "Mac-Localizable") }

    /// "Shown in tray app"
    /// "Get more storage"
    public static var general_get_more_storage: String { localized(key: "general_get_more_storage", table: "Mac-Localizable") }

    /// "Button to quit application"
    /// "Quit"
    public static var general_quit: String { localized(key: "general_quit", table: "Mac-Localizable") }

    /// "Launching... (%d%%)"
    public static func menu_launching_percentage(launchCompletion: Int) -> String { String(format: localized(key: "menu_launching_percentage", table: "Mac-Localizable"), launchCompletion) }

    /// "Label text when mac is offline"
    /// "Offline"
    public static var menu_offline: String { localized(key: "menu_offline", table: "Mac-Localizable") }

    /// "Label text when performing full resync"
    /// "Performing full resync..."
    public static var menu_status_full_resync: String { localized(key: "menu_status_full_resync", table: "Mac-Localizable") }

    /// "Label text when mac is offline"
    /// "You are offline"
    public static var menu_status_offline: String { localized(key: "menu_status_offline", table: "Mac-Localizable") }

    /// "Label text when user is signed out "
    /// "Signed out"
    public static var menu_status_signed_out: String { localized(key: "menu_status_signed_out", table: "Mac-Localizable") }

    /// "how many items have been numerated so far"
    /// "Listing changes... (%d items)"
    public static func menu_status_sync_enumerating(itemsEnumerated: Int) -> String { String(format: localized(key: "menu_status_sync_enumerating", table: "Mac-Localizable"), itemsEnumerated) }

    /// "how many items failed to sync"
    /// "%d item failed to sync"
    public static func menu_status_sync_items_failed(errorCount: Int) -> String { String(format: localized(key: "menu_status_sync_items_failed", table: "Mac-Localizable"), errorCount) }

    /// "Label text when initializing sync"
    /// "Initializing sync..."
    public static var menu_status_sync_launching: String { localized(key: "menu_status_sync_launching", table: "Mac-Localizable") }

    /// "Label text when sync paused "
    /// "Sync paused"
    public static var menu_status_sync_paused: String { localized(key: "menu_status_sync_paused", table: "Mac-Localizable") }

    /// "Label text when synced"
    /// "Your files are up to date"
    public static var menu_status_synced: String { localized(key: "menu_status_synced", table: "Mac-Localizable") }

    /// "Label text when syncing "
    /// "Syncing..."
    public static var menu_status_syncing: String { localized(key: "menu_status_syncing", table: "Mac-Localizable") }

    /// "Label text when new version of app is available"
    /// "Update available"
    public static var menu_status_update_available: String { localized(key: "menu_status_update_available", table: "Mac-Localizable") }

    /// "Sign out"
    public static var menu_text_logout: String { localized(key: "menu_text_logout", table: "Mac-Localizable") }

    /// "Remove sync folder & sign out"
    public static var menu_text_logout_remove_domain: String { localized(key: "menu_text_logout_remove_domain", table: "Mac-Localizable") }

    /// "Button to expand text view for error deteail"
    /// "Details"
    public static var notification_details: String { localized(key: "notification_details", table: "Mac-Localizable") }

    /// "Error text"
    /// "There is %d issue"
    public static func notification_issues(num: Int) -> String { String(format: localized(key: "notification_issues", table: "Mac-Localizable"), num) }

    /// "Dismissible banner in the tray window during an automatic refresh of the file list, explaining that syncing is suspended until the refresh finishes. Wraps to at most two lines in a 360pt-wide window."
    /// "Syncing suspended until the refresh finishes."
    public static var notification_resync_auto_reason: String { localized(key: "notification_resync_auto_reason", table: "Mac-Localizable") }

    /// "Button to restart application"
    /// "Update available — click to restart and install."
    public static var notification_update_available: String { localized(key: "notification_update_available", table: "Mac-Localizable") }

    /// "Notification shown when the user\'s volume is locked on the backend"
    /// "Your files are locked and can\'t sync"
    public static var notification_volume_locked: String { localized(key: "notification_volume_locked", table: "Mac-Localizable") }

    /// "Banner inviting the user to restore access to their locked volume via the web recovery flow"
    /// "Restore access to your locked files"
    public static var notification_volume_locked_restore: String { localized(key: "notification_volume_locked_restore", table: "Mac-Localizable") }

    /// "Message shown in the mac onboarding view"
    /// "Open your folder and click Enable to finish setting up Proton Drive on your Mac."
    public static var onboarding_desc: String { localized(key: "onboarding_desc", table: "Mac-Localizable") }

    /// "Button title shown on the mac onboarding view"
    /// "Open your Proton Drive folder"
    public static var onboarding_start_button: String { localized(key: "onboarding_start_button", table: "Mac-Localizable") }

    /// "Title shown in the mac onboarding view"
    /// "You’re nearly there!"
    public static var onboarding_title: String { localized(key: "onboarding_title", table: "Mac-Localizable") }

    /// "Account setting section title"
    /// "Account"
    public static var setting_account: String { localized(key: "setting_account", table: "Mac-Localizable") }

    /// "Button title"
    /// "Manage account"
    public static var setting_account_manage_account: String { localized(key: "setting_account_manage_account", table: "Mac-Localizable") }

    /// "Fix syncing issues section title"
    /// "Fix syncing issues"
    public static var setting_fix_syncing_issues: String { localized(key: "setting_fix_syncing_issues", table: "Mac-Localizable") }

    /// "Fix syncing issues section button title"
    /// "Resync"
    public static var setting_fix_syncing_issues_button: String { localized(key: "setting_fix_syncing_issues_button", table: "Mac-Localizable") }

    /// "Fix syncing issues section description"
    /// "If you\'re having trouble syncing, try resyncing to make sure your data is up to date. This may take some time, depending on how many files you have."
    public static var setting_fix_syncing_issues_description: String { localized(key: "setting_fix_syncing_issues_description", table: "Mac-Localizable") }

    /// "Settings resync section: opens the About resync popover"
    /// "Learn more"
    public static var setting_fix_syncing_issues_learn_more: String { localized(key: "setting_fix_syncing_issues_learn_more", table: "Mac-Localizable") }

    /// "Get help section title"
    /// "Get help"
    public static var setting_get_help: String { localized(key: "setting_get_help", table: "Mac-Localizable") }

    /// "This is markdown text\nPlease move [support website](%@) together"
    /// "You will find additional help on our [support website](%@)"
    public static func setting_help_additional_help(link: String) -> String { String(format: localized(key: "setting_help_additional_help", table: "Mac-Localizable"), link) }

    /// "Label text to encourage user report issue"
    /// "If you are facing any problems, please report the issue."
    public static var setting_help_report_encourage_text: String { localized(key: "setting_help_report_encourage_text", table: "Mac-Localizable") }

    /// "Button title"
    /// "Report an issue"
    public static var setting_help_report_issue: String { localized(key: "setting_help_report_issue", table: "Mac-Localizable") }

    /// "Button title"
    /// "Show logs"
    public static var setting_help_show_logs: String { localized(key: "setting_help_show_logs", table: "Mac-Localizable") }

    /// "Version %@"
    public static func setting_mac_version(version: String) -> String { String(format: localized(key: "setting_mac_version", table: "Mac-Localizable"), version) }

    /// "Storage setting section title"
    /// "Storage"
    public static var setting_storage: String { localized(key: "setting_storage", table: "Mac-Localizable") }

    /// "Out of storage"
    public static var setting_storage_out_of_storage: String { localized(key: "setting_storage_out_of_storage", table: "Mac-Localizable") }

    /// "Syncing has been paused. Please upgrade or free up space to resume syncing."
    public static var setting_storage_out_of_storage_warning: String { localized(key: "setting_storage_out_of_storage_warning", table: "Mac-Localizable") }

    /// "Using \\(currentStorage) of \\(maxStorage)"
    /// "Using %@ of %@"
    public static func setting_storage_usage_info(currentStorage: String, maxStorage: String) -> String { String(format: localized(key: "setting_storage_usage_info", table: "Mac-Localizable"), currentStorage, maxStorage) }

    /// "System setting section title"
    /// "System"
    public static var setting_system: String { localized(key: "setting_system", table: "Mac-Localizable") }

    /// "Information text"
    /// "Checking for update ..."
    public static var setting_system_checking_update: String { localized(key: "setting_system_checking_update", table: "Mac-Localizable") }

    /// "Information text"
    /// "Downloading new version ..."
    public static var setting_system_downloading: String { localized(key: "setting_system_downloading", table: "Mac-Localizable") }

    /// "Toggle title"
    /// "Launch on startup"
    public static var setting_system_launch_on_startup: String { localized(key: "setting_system_launch_on_startup", table: "Mac-Localizable") }

    /// "Information text"
    /// "New version available"
    public static var setting_system_new_version_available: String { localized(key: "setting_system_new_version_available", table: "Mac-Localizable") }

    /// "Information text"
    /// "Proton Drive is up to date"
    public static var setting_system_up_to_date: String { localized(key: "setting_system_up_to_date", table: "Mac-Localizable") }

    /// "Button title"
    /// "Update now"
    public static var setting_system_update_button: String { localized(key: "setting_system_update_button", table: "Mac-Localizable") }

    /// "Terms and Conditions"
    public static var setting_terms_and_condition: String { localized(key: "setting_terms_and_condition", table: "Mac-Localizable") }

    /// "Version %@"
    public static func setting_version(version: String) -> String { String(format: localized(key: "setting_version", table: "Mac-Localizable"), version) }

    /// "Button title to pause sync"
    /// "Pause Syncing"
    public static var sync_pause: String { localized(key: "sync_pause", table: "Mac-Localizable") }

    /// "Button title to resume sync"
    /// "Resume Syncing"
    public static var sync_resume: String { localized(key: "sync_resume", table: "Mac-Localizable") }

    /// "Create a new album to add photos"
    /// "Add to new album"
    public static var action_add_to_new_album: String { localized(key: "action_add_to_new_album", table: "shared-Localizable") }

    /// "action title to delete album"
    /// "Delete album"
    public static var action_delete_album: String { localized(key: "action_delete_album", table: "shared-Localizable") }

    /// "action title to delete album"
    /// "Delete without saving"
    public static var action_delete_without_saving: String { localized(key: "action_delete_without_saving", table: "shared-Localizable") }

    /// "Action title to leave album shared to me "
    /// "Leave album"
    public static var action_leave_album: String { localized(key: "action_leave_album", table: "shared-Localizable") }

    /// "Create a new shared album to share photos"
    /// "New shared album"
    public static var action_new_shared_album: String { localized(key: "action_new_shared_album", table: "shared-Localizable") }

    /// "Button title to remove selected photos from the album"
    /// "Remove from album"
    public static var action_remove_photos: String { localized(key: "action_remove_photos", table: "shared-Localizable") }

    /// "Button title to rename album"
    /// "Rename album"
    public static var action_rename_album: String { localized(key: "action_rename_album", table: "shared-Localizable") }

    /// "action title to save photos and delete album"
    /// "Save photos and remove"
    public static var action_save_and_remove: String { localized(key: "action_save_and_remove", table: "shared-Localizable") }

    /// "Share photos via link"
    /// "Send link"
    public static var action_send_link: String { localized(key: "action_send_link", table: "shared-Localizable") }

    /// "Set the selected photo as album cover"
    /// "Set as album cover"
    public static var action_set_as_album_cover: String { localized(key: "action_set_as_album_cover", table: "shared-Localizable") }

    /// "Action title to sort items"
    /// "Sort"
    public static var action_sort: String { localized(key: "action_sort", table: "shared-Localizable") }

    /// "Message shown to user when edit album success"
    /// "Edits saved"
    public static var album_edit_saved: String { localized(key: "album_edit_saved", table: "shared-Localizable") }

    /// "Warning message when the user tries to delete selected photos from the album\nPLEASE keep `, %d` in the end, this is to fix plural limitation"
    /// "What would you like to do with this item?,%d"
    public static func album_photo_remove_warning(num: Int) -> String { String(format: localized(key: "album_photo_remove_warning", table: "shared-Localizable"), num) }

    /// "Are you sure you want to remove the selected item(s) from your album?"
    public static var album_photo_remove_warning_admin: String { localized(key: "album_photo_remove_warning_admin", table: "shared-Localizable") }

    /// "Remove"
    public static var album_photo_remove_warning_admin_confirmation: String { localized(key: "album_photo_remove_warning_admin_confirmation", table: "shared-Localizable") }

    /// "Warning message when the user tries to delete selected photos from the album\nPLEASE keep `, %d` in the end, this is to fix plural limitation"
    /// "You’ll lose access to this photo. If you haven’t already, save it to your photo timeline before removing it from the album."
    public static func album_photo_remove_warning_editor(num: Int) -> String { String(format: localized(key: "album_photo_remove_warning_editor", table: "shared-Localizable"), num) }

    /// "Continue"
    public static var album_photo_remove_warning_editor_continue: String { localized(key: "album_photo_remove_warning_editor_continue", table: "shared-Localizable") }

    /// "Textfield placeholder"
    /// "Album name"
    public static var create_album_placeholder: String { localized(key: "create_album_placeholder", table: "shared-Localizable") }

    /// "Alert message to delete album"
    /// "Are you sure you want to delete the album “%@”? The photos will not be deleted."
    public static func delete_album_alert_message(name: String) -> String { String(format: localized(key: "delete_album_alert_message", table: "shared-Localizable"), name) }

    /// "Alert title to delete album"
    /// "Delete “%@”"
    public static func delete_album_alert_title(name: String) -> String { String(format: localized(key: "delete_album_alert_title", table: "shared-Localizable"), name) }

    /// "Warning text before deleting album that contains photos don\'t in the photo stream"
    /// "Some photos in this album are not saved to your timeline. Deleting this album will permanently delete those photos.\n\nWould you like to save them before removing?"
    public static var delete_album_and_move_alert_message: String { localized(key: "delete_album_and_move_alert_message", table: "shared-Localizable") }

    /// "Shown in tray app"
    /// "Detecting remote changes"
    public static var detecting_remote_changes: String { localized(key: "detecting_remote_changes", table: "shared-Localizable") }

    /// "Title shown in the view when device is disconnected"
    /// "Your device has no connection"
    public static var disconnection_view_title: String { localized(key: "disconnection_view_title", table: "shared-Localizable") }

    /// "Button to move item to trash"
    /// "Move to trash"
    public static var edit_section_remove: String { localized(key: "edit_section_remove", table: "shared-Localizable") }

    /// "Error message displayed when the user attempts to access a permanently deleted file or folder"
    /// "File or folder not found"
    public static var error_not_found: String { localized(key: "error_not_found", table: "shared-Localizable") }

    /// "Concat with other string, e.g. Restore 4 files, Delete 1 file"
    /// "%d File"
    public static func file_plural_type_with_num(num: Int) -> String { String(format: localized(key: "file_plural_type_with_num", table: "shared-Localizable"), num) }

    /// "Concat with other string, e.g. Restore 4 folders, Delete 1 folder"
    /// "%d Folder"
    public static func folder_plural_type_with_num(num: Int) -> String { String(format: localized(key: "folder_plural_type_with_num", table: "shared-Localizable"), num) }

    /// "Gallery title to display the album gallery"
    /// "Albums"
    public static var gallery_title_albums: String { localized(key: "gallery_title_albums", table: "shared-Localizable") }

    /// "Gallery title to display the photo gallery"
    /// "Photos"
    public static var gallery_title_photos: String { localized(key: "gallery_title_photos", table: "shared-Localizable") }

    /// "Button to add photo...etc"
    /// "Add"
    public static var general_add: String { localized(key: "general_add", table: "shared-Localizable") }

    /// "Button title"
    /// "Cancel"
    public static var general_cancel: String { localized(key: "general_cancel", table: "shared-Localizable") }

    /// "Button title"
    /// "Delete"
    public static var general_delete: String { localized(key: "general_delete", table: "shared-Localizable") }

    /// "Button to dismiss page, banner..etc"
    /// "Dismiss"
    public static var general_dismiss: String { localized(key: "general_dismiss", table: "shared-Localizable") }

    /// "Button to edit, edit title...etc"
    /// "Edit"
    public static var general_edit: String { localized(key: "general_edit", table: "shared-Localizable") }

    /// "Concat with other string, e.g. Restore file, Delete file"
    /// "File"
    public static var general_file_type: String { localized(key: "general_file_type", table: "shared-Localizable") }

    /// "Concat with other string, e.g. Restore folder, Delete folder"
    /// "Folder"
    public static var general_folder_type: String { localized(key: "general_folder_type", table: "shared-Localizable") }

    /// "Concat with other string, e.g. Restore item, Delete item"
    /// "Item"
    public static var general_item_type: String { localized(key: "general_item_type", table: "shared-Localizable") }

    /// "Button title"
    /// "OK"
    public static var general_ok: String { localized(key: "general_ok", table: "shared-Localizable") }

    /// "Button title"
    /// "Rename"
    public static var general_rename: String { localized(key: "general_rename", table: "shared-Localizable") }

    /// "Button title"
    /// "Restore"
    public static var general_restore: String { localized(key: "general_restore", table: "shared-Localizable") }

    /// "Button to retry action after failing "
    /// "Retry"
    public static var general_retry: String { localized(key: "general_retry", table: "shared-Localizable") }

    /// "button title"
    /// "Settings"
    public static var general_settings: String { localized(key: "general_settings", table: "shared-Localizable") }

    /// "Button to open share config"
    /// "Share"
    public static var general_share: String { localized(key: "general_share", table: "shared-Localizable") }

    /// "Banner message shown after the selected items have been successfully added to the album"
    /// "%d item added to album"
    public static func item_add_to_album(num: Int) -> String { String(format: localized(key: "item_add_to_album", table: "shared-Localizable"), num) }

    /// "Banner message shown after the selected items have been successfully added to the photo stream"
    /// "%d item added to your stream"
    public static func item_add_to_photo_stream(num: Int) -> String { String(format: localized(key: "item_add_to_photo_stream", table: "shared-Localizable"), num) }

    /// "Banner message shown after the selected items already exist in the album"
    /// "%d item already exist"
    public static func item_already_exist(num: Int) -> String { String(format: localized(key: "item_already_exist", table: "shared-Localizable"), num) }

    /// "Banner message shown after the selected items are not fully uploaded"
    /// "%d item is not fully uploaded"
    public static func item_failed_incomplete(num: Int) -> String { String(format: localized(key: "item_failed_incomplete", table: "shared-Localizable"), num) }

    /// "Failed to add the selected photos to the album."
    /// "%d item failed to add"
    public static func item_failed_to_add(num: Int) -> String { String(format: localized(key: "item_failed_to_add", table: "shared-Localizable"), num) }

    /// "Failed to remove the selected photos to the album."
    /// "%d item failed to remove"
    public static func item_failed_to_remove(num: Int) -> String { String(format: localized(key: "item_failed_to_remove", table: "shared-Localizable"), num) }

    /// "Concat with other string, e.g. Restore 4 items, Delete 1 item"
    /// "%d Item"
    public static func item_plural_type_with_num(num: Int) -> String { String(format: localized(key: "item_plural_type_with_num", table: "shared-Localizable"), num) }

    /// "Banner message shown after the selected items have been successfully removed from the album"
    /// "%d item removed from album"
    public static func item_remove_from_album(num: Int) -> String { String(format: localized(key: "item_remove_from_album", table: "shared-Localizable"), num) }

    /// "Banner message shown after the selected items have been successfully removed from the photo stream"
    /// "%d item removed from stream"
    public static func item_remove_from_photo_stream(num: Int) -> String { String(format: localized(key: "item_remove_from_photo_stream", table: "shared-Localizable"), num) }

    /// "Listing local files and folders"
    public static var listing_local_files: String { localized(key: "listing_local_files", table: "shared-Localizable") }

    /// "Label text to show total drive storage usage "
    /// "Total usage"
    public static var menu_text_total_usage: String { localized(key: "menu_text_total_usage", table: "shared-Localizable") }

    /// "name validation error, the name only contains dot which is not allowed "
    /// "\".\" is not a valid name"
    public static var name_validation_dot: String { localized(key: "name_validation_dot", table: "shared-Localizable") }

    /// "name validation error, name contains invisible characters"
    /// "Name cannot include invisible characters, / or \\."
    public static var name_validation_invisible_chars: String { localized(key: "name_validation_invisible_chars", table: "shared-Localizable") }

    /// "Name must not begin with a space"
    public static var name_validation_leading_white: String { localized(key: "name_validation_leading_white", table: "shared-Localizable") }

    /// "name validation error, given empty name"
    /// "Name must not be empty"
    public static var name_validation_non_empty: String { localized(key: "name_validation_non_empty", table: "shared-Localizable") }

    /// "name validation error, longer than 255"
    /// "Name is too long"
    public static var name_validation_too_long: String { localized(key: "name_validation_too_long", table: "shared-Localizable") }

    /// "Name must not end with a space"
    public static var name_validation_trailing_white: String { localized(key: "name_validation_trailing_white", table: "shared-Localizable") }

    /// "name validation error, the name only contains 2 dots which is not allowed "
    /// "\"..\" is not a valid name"
    public static var name_validation_two_dot: String { localized(key: "name_validation_two_dot", table: "shared-Localizable") }

    /// "Label for button which opens a file"
    /// "Open"
    public static var open: String { localized(key: "open", table: "shared-Localizable") }

    /// "Add selected photos to shared album"
    /// "Add to shared album"
    public static var section_add_to_shared_album: String { localized(key: "section_add_to_shared_album", table: "shared-Localizable") }

    /// "Section title for share options"
    /// "Share via"
    public static var section_share_via: String { localized(key: "section_share_via", table: "shared-Localizable") }

    /// "Newest first"
    public static var sort_newest_first: String { localized(key: "sort_newest_first", table: "shared-Localizable") }

    /// "Oldest first"
    public static var sort_oldest_first: String { localized(key: "sort_oldest_first", table: "shared-Localizable") }

    /// "Recently added"
    public static var sort_recently_added: String { localized(key: "sort_recently_added", table: "shared-Localizable") }

    /// "Label text, sort files by file type"
    /// "File type"
    public static var sort_type_file_type: String { localized(key: "sort_type_file_type", table: "shared-Localizable") }

    /// "Label text, sort files by last modified date"
    /// "Last modified"
    public static var sort_type_last_modified: String { localized(key: "sort_type_last_modified", table: "shared-Localizable") }

    /// "Label text, sort files by file name"
    /// "Name"
    public static var sort_type_name: String { localized(key: "sort_type_name", table: "shared-Localizable") }

    /// "Label text, sort files by file size"
    /// "Size"
    public static var sort_type_size: String { localized(key: "sort_type_size", table: "shared-Localizable") }

    /// "Filter tag to show all photos"
    /// "All"
    public static var tag_all: String { localized(key: "tag_all", table: "shared-Localizable") }

    /// "Filter tag to show burst"
    /// "Burst"
    public static var tag_burst: String { localized(key: "tag_burst", table: "shared-Localizable") }

    /// "Filter tag to show favorite photos"
    /// "Favorites"
    public static var tag_favorites: String { localized(key: "tag_favorites", table: "shared-Localizable") }

    /// "Filter tag to show live photos"
    /// "Live Photos"
    public static var tag_livePhotos: String { localized(key: "tag_livePhotos", table: "shared-Localizable") }

    /// "Filter tag to show motion photos"
    /// "Motion Photos"
    public static var tag_motionPhotos: String { localized(key: "tag_motionPhotos", table: "shared-Localizable") }

    /// "Filter tag to show my albums"
    /// "My albums"
    public static var tag_myAlbum: String { localized(key: "tag_myAlbum", table: "shared-Localizable") }

    /// "Filter tag to show panoramas"
    /// "Panoramas"
    public static var tag_panoramas: String { localized(key: "tag_panoramas", table: "shared-Localizable") }

    /// "Filter tag to show portraits"
    /// "Portraits"
    public static var tag_portraits: String { localized(key: "tag_portraits", table: "shared-Localizable") }

    /// "Filter tag to show raw photo"
    /// "RAW"
    public static var tag_raw: String { localized(key: "tag_raw", table: "shared-Localizable") }

    /// "Filter tag to show screenshot"
    /// "Screenshots"
    public static var tag_screenshots: String { localized(key: "tag_screenshots", table: "shared-Localizable") }

    /// "Filter tag to show selfies"
    /// "Selfies"
    public static var tag_selfies: String { localized(key: "tag_selfies", table: "shared-Localizable") }

    /// "Filter tag to show album shared by me"
    /// "Shared"
    public static var tag_shared: String { localized(key: "tag_shared", table: "shared-Localizable") }

    /// "Filter tag to show album shared with me"
    /// "Shared with me"
    public static var tag_sharedWithMe: String { localized(key: "tag_sharedWithMe", table: "shared-Localizable") }

    /// "Filter tag to show videos"
    /// "Videos"
    public static var tag_videos: String { localized(key: "tag_videos", table: "shared-Localizable") }

    /// "View title"
    /// "Rename Album"
    public static var title_rename_album: String { localized(key: "title_rename_album", table: "shared-Localizable") }

    /// "Action to restore all trashed files"
    /// "Restore all files"
    public static var trash_action_restore_all_files: String { localized(key: "trash_action_restore_all_files", table: "shared-Localizable") }

    /// "Action to restore all trashed files"
    /// "Restore all folders"
    public static var trash_action_restore_all_folders: String { localized(key: "trash_action_restore_all_folders", table: "shared-Localizable") }

    /// "Action to restore all trashed items"
    /// "Restore all items"
    public static var trash_action_restore_all_items: String { localized(key: "trash_action_restore_all_items", table: "shared-Localizable") }

}

#endif
