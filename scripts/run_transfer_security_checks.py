#!/usr/bin/env python3
"""Run focused mocked security checks in a disposable inert host and unique app namespace.

Copies source/resources only, never an app container or Keychain data. The full standard
app must also be compiled separately: this harness deliberately replaces only its entry.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('simulator')
parser.add_argument('--canonical-project', required=True, type=Path)
parser.add_argument('--only', action='append', default=[], help='Retained unit test class or class/method; repeatable')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
base = args.output.resolve()
base.mkdir(parents=True, exist_ok=False)
source = base / 'source'
source.mkdir()
for folder in ['MassiveX', 'MassiveXTests', 'Vendor']:
    shutil.copytree(root / folder, source / folder)
project = source / 'MassiveX.xcodeproj'
project.mkdir()
namespace = 'com.massivex.tests.' + uuid.uuid4().hex
(project / 'project.pbxproj').write_text(args.canonical_project.read_text().replace('com.massivex.wallet', namespace))
shutil.copytree(root / 'MassiveX.xcodeproj/xcshareddata', project / 'xcshareddata')
(source / 'MassiveX/App/MassiveXApp.swift').write_text('''import SwiftUI
import UserNotifications
enum AppTab: Hashable { case wallet, activity, settings }
@main struct MassiveXApp: App {
    var body: some Scene { WindowGroup { Text("Isolated security checks") } }
}
final class MassiveXApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {}
''')
suites = ['TransferTrustRecoveryTests', 'SendCoordinatorTests', 'TransferRPCTests',
          'StandardSendIntegrationTests', 'ReconciliationEvidenceTests', 'JournalRecoveryTests',
          'BoundedTransportTests', 'WalletRemovalSecurityTests', 'OperationIDTests', 'TransferCompatibilityTests']
cases = ['testResetCancellationThenScopedOwnedAndWatchCleanupPreservesUnknownArchive',
         'testFailedKeyDeletionRetainsRecoverableRecord', 'testDeletionQueryIsNarrowAndDoesNotEnumerateKeys',
         'testResetRejectsLateBalanceAndNotificationCallback', 'testLogoutLabelAndConfirmationAreLocalizedIncludingExactRussianAction']
command = ['xcodebuild', '-quiet', '-project', str(project), '-scheme', 'MassiveX', '-configuration', 'Debug',
           '-destination', 'platform=iOS Simulator,id=' + args.simulator, '-destination-timeout', '30',
           '-derivedDataPath', str(base / 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO',
           '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
           '-resultBundlePath', str(base / 'tests.xcresult')]
if args.only:
    command += ['-only-testing:MassiveXTests/' + selection for selection in args.only]
else:
    for suite in suites:
        command += ['-only-testing:MassiveXTests/' + suite]
    for case in cases:
        command += ['-only-testing:MassiveXTests/WalletSettingsTests/' + case]
command += ['test']
with (base / 'command.txt').open('w') as log:
    import shlex
    log.write(shlex.join(command) + '\n')
with (base / 'xcodebuild.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
print('Isolated security xcodebuild exit:', result.returncode)
raise SystemExit(result.returncode)
