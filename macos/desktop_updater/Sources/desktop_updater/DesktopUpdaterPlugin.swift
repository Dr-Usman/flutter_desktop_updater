import Cocoa
import FlutterMacOS

public class DesktopUpdaterPlugin: NSObject, FlutterPlugin {
    func getCurrentVersion() -> String {
        let infoDictionary = Bundle.main.infoDictionary!
        let version = infoDictionary["CFBundleVersion"] as! String
        return version
    }

    func restartApp() {
        let fileManager = FileManager.default

        let appBundlePath = Bundle.main.bundlePath
        guard let executablePath = Bundle.main.executablePath else {
            print("Executable path not found")
            return
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            print("Bundle identifier not found")
            return
        }

        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSpecificDir = appSupportDir.appendingPathComponent(bundleIdentifier)
        let updateFolder = appSpecificDir
            .appendingPathComponent("updates")
            .appendingPathComponent("update")
            .path

        let logsDir = appSpecificDir.appendingPathComponent("logs")
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        do {
            let logFiles = try fileManager
                .contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "log" }
                .sorted { url1, url2 in
                    let date1 = try url1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    let date2 = try url2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    return date1 > date2
                }

            if logFiles.count >= 2 {
                for logFile in logFiles[2...] {
                    try? fileManager.removeItem(at: logFile)
                }
            }
        } catch {
            print("Error managing log rotation: \(error)")
        }

        let logFile = logsDir.appendingPathComponent("update_\(Int(Date().timeIntervalSince1970)).log")
        let appPid = String(ProcessInfo.processInfo.processIdentifier)

        let scriptPath = NSTemporaryDirectory() + "update_and_restart.sh"

        let scriptContent = """
        #!/bin/bash
        APP_BUNDLE_PATH="$1"
        UPDATE_FOLDER_PATH="$2"
        EXECUTABLE_PATH="$3"
        LOG_FILE="$4"
        APP_PID="$5"

        log_message() {
            local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
            echo "$message" | tee -a "$LOG_FILE"
        }

        is_pid_running() {
            if [ -z "$APP_PID" ]; then
                return 1
            fi
            kill -0 "$APP_PID" >/dev/null 2>&1
            return $?
        }

        is_app_running_by_path() {
            pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1
            return $?
        }

        log_message "Starting update process..."
        log_message "App Bundle Path: $APP_BUNDLE_PATH"
        log_message "Update Folder Path: $UPDATE_FOLDER_PATH"
        log_message "Executable Path: $EXECUTABLE_PATH"
        log_message "Log File: $LOG_FILE"
        log_message "Original PID: $APP_PID"

        if [ ! -d "$UPDATE_FOLDER_PATH" ]; then
            log_message "Error: Update folder does not exist: $UPDATE_FOLDER_PATH"
            exit 1
        fi

        log_message "Update folder contents:"
        ls -la "$UPDATE_FOLDER_PATH" | tee -a "$LOG_FILE"

        UPDATE_FILES_COUNT=$(ls -1 "$UPDATE_FOLDER_PATH" | wc -l | tr -d ' ')
        if [ "$UPDATE_FILES_COUNT" -eq 0 ]; then
            log_message "Error: Update folder is empty"
            exit 1
        fi
        log_message "Found $UPDATE_FILES_COUNT files to update"

        log_message "Terminating current application instance..."
        if is_pid_running; then
            log_message "Found running app PID: $APP_PID"
            kill -TERM "$APP_PID" >/dev/null 2>&1 || true
            sleep 2
            if is_pid_running; then
                log_message "Application still running, sending SIGKILL to PID $APP_PID"
                kill -KILL "$APP_PID" >/dev/null 2>&1 || true
            fi
        else
            log_message "PID not running, trying executable path match"
            APP_PATH_PID=$(pgrep -f "$EXECUTABLE_PATH" | head -n 1)
            if [ -n "$APP_PATH_PID" ]; then
                log_message "Found app by path PID: $APP_PATH_PID"
                kill -TERM "$APP_PATH_PID" >/dev/null 2>&1 || true
                sleep 2
                if pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
                    log_message "Application still running, sending SIGKILL to PID $APP_PATH_PID"
                    kill -KILL "$APP_PATH_PID" >/dev/null 2>&1 || true
                fi
            else
                log_message "No running instance found"
            fi
        fi

        TIMEOUT=20
        COUNT=0
        while (is_pid_running || is_app_running_by_path) && [ $COUNT -lt $TIMEOUT ]; do
            sleep 1
            COUNT=$((COUNT + 1))
            log_message "Waiting for application to close... ($COUNT/$TIMEOUT)"
        done

        if is_pid_running || is_app_running_by_path; then
            log_message "Error: Application failed to close after $TIMEOUT seconds"
            exit 1
        fi
        log_message "Application terminated successfully"

        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "Error: Original bundle does not exist: $APP_BUNDLE_PATH"
            exit 1
        fi

        APP_DIR="$(dirname "$APP_BUNDLE_PATH")"
        TEMP_DIR=$(mktemp -d "${APP_DIR}/.update.XXXXXX" 2>/dev/null)
        if [ ! -d "$TEMP_DIR" ]; then
            TEMP_DIR=$(mktemp -d)
        fi
        log_message "Created temporary directory: $TEMP_DIR"

        log_message "Copying bundle (reflink -> ditto -> cp fallback)..."
        if cp -R -c "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>/dev/null; then
            log_message "  Used reflink clone"
        elif ditto "$APP_BUNDLE_PATH" "$TEMP_DIR/$(basename "$APP_BUNDLE_PATH")" 2>/dev/null; then
            log_message "  Used ditto"
        elif cp -R "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  Used cp -R"
        else
            log_message "Error: Failed to copy bundle to temporary directory"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        TEMP_BUNDLE="$TEMP_DIR/$(basename "$APP_BUNDLE_PATH")"
        log_message "Temporary bundle path: $TEMP_BUNDLE"

        if [ ! -d "$TEMP_BUNDLE" ]; then
            log_message "Error: Temporary bundle was not created correctly"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        log_message "Clearing inherited xattrs from temporary bundle"
        xattr -cr "$TEMP_BUNDLE" >/dev/null 2>&1 || true
        DEST_DIR="$TEMP_BUNDLE/Contents"

        log_message "Overlaying update files: $UPDATE_FOLDER_PATH -> $DEST_DIR"
        if rsync -a --delete --exclude='*.log' --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "$UPDATE_FOLDER_PATH/" "$DEST_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  Update files overlayed"
        else
            log_message "Error: rsync overlay failed"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        EXECUTABLE_NAME="$(basename "$EXECUTABLE_PATH")"
        TEMP_EXECUTABLE="$DEST_DIR/MacOS/$EXECUTABLE_NAME"
        if [ ! -f "$TEMP_EXECUTABLE" ]; then
            log_message "Error: Executable missing after overlay: $TEMP_EXECUTABLE"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        log_message "Setting executable permissions..."
        chmod -v +x "$TEMP_EXECUTABLE" 2>&1 | tee -a "$LOG_FILE"
        CHMOD_EXIT=$?
        log_message "chmod exit code: $CHMOD_EXIT"

        if [ ! -x "$TEMP_EXECUTABLE" ]; then
            log_message "Primary chmod did not produce executable bit. Applying fallback chmod on Contents/MacOS"
            if [ -d "$DEST_DIR/MacOS" ]; then
                find "$DEST_DIR/MacOS" -type f -exec chmod +x {} \\; 2>&1 | tee -a "$LOG_FILE"
            fi
        fi

        if [ ! -x "$TEMP_EXECUTABLE" ]; then
            log_message "Error: Temporary executable still not executable"
            ls -la "$(dirname "$TEMP_EXECUTABLE")" | tee -a "$LOG_FILE"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        BACKUP_PATH="$APP_BUNDLE_PATH.backup"
        log_message "Creating backup at: $BACKUP_PATH"
        if ! mv "$APP_BUNDLE_PATH" "$BACKUP_PATH"; then
            log_message "Error: Failed to create backup"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        log_message "Moving temporary bundle to final location..."
        if ! mv "$TEMP_BUNDLE" "$APP_BUNDLE_PATH"; then
            log_message "Error: Failed to move bundle to final location"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" >/dev/null 2>&1 || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "Error: Final bundle does not exist"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" >/dev/null 2>&1 || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        rm -rf "$TEMP_DIR"
        rm -rf "$UPDATE_FOLDER_PATH"

        log_message "Re-signing application bundle ad-hoc..."
        if codesign --force --deep --sign - "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  App bundle re-signed successfully"
        else
            log_message "  Warning: Re-signing failed, app may not launch"
        fi

        log_message "Launching application..."
        xattr -dr com.apple.quarantine "$APP_BUNDLE_PATH" >/dev/null 2>&1 || true
        open "$APP_BUNDLE_PATH"

        START_TIMEOUT=60
        START_COUNT=0
        while ! pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1 && [ $START_COUNT -lt $START_TIMEOUT ]; do
            sleep 1
            START_COUNT=$((START_COUNT + 1))
            log_message "Waiting for application to start... ($START_COUNT/$START_TIMEOUT)"
        done

        if pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
            log_message "Application launched successfully"
            rm -rf "$BACKUP_PATH"
            exit 0
        else
            log_message "Error: Application failed to start after $START_TIMEOUT seconds"
            rm -rf "$APP_BUNDLE_PATH"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" >/dev/null 2>&1 || true
            exit 1
        fi
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            print("Error writing shell script: \(error)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, appBundlePath, updateFolder, executablePath, logFile.path, appPid]

        do {
            try process.run()
            print("Update script started")
        } catch {
            print("Failed to run update script: \(error)")
            return
        }

        // Terminate immediately after starting script so the updater can replace the bundle.
        NSApplication.shared.terminate(nil)
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "desktop_updater", binaryMessenger: registrar.messenger)
        let instance = DesktopUpdaterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        case "restartApp":
            restartApp()
            result(nil)
        case "getExecutablePath":
            result(Bundle.main.executablePath)
        case "getCurrentVersion":
            result(getCurrentVersion())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
