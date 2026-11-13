# Fix Flutter JDK Configuration

## Scope and Evidence

- Fix the supplied PowerShell errors only: `lutter` is a typo, and the unquoted JDK path is split into multiple arguments.
- Confirmed the installed folder `C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot` exists; its `release` file identifies Eclipse Adoptium Java `17.0.20.1`.
- No source, dependency, native-project, or environment-variable changes are required. This does not establish whether the application has other build or analyzer errors.

## Implementation

1. Record the existing `jdk-dir` value using `flutter config --list`. This setting applies to Flutter tooling across projects, not just Salahly.
2. Run the corrected command from any directory. Keep the path quoted, use `flutter`, and do not insert a space after `=`:

   ```powershell
   flutter config --jdk-dir="C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot"
   ```

3. Run `flutter doctor -v`. Confirm Flutter reports the configured JDK's `bin\java` executable and Java 17. Do not use bare `java -version` as the only check: it may resolve a different Java installation from PATH.
4. If the original project problem remains, run `flutter analyze --no-pub` from `D:\Developing\side job\salhly` and capture the actual diagnostics. For a launch failure, capture `flutter run` output with an available target device. Diagnose any new error separately; do not bulk-upgrade packages or edit Gradle speculatively.

## Validation and Recovery

- Success for this change means the config command no longer reports excess arguments and `flutter doctor -v` confirms the intended Java installation.
- Report unrelated doctor warnings separately. Configuring Java does not launch the application or clear Dart source diagnostics.
- If another Flutter project needs the previous JDK, restore the recorded `jdk-dir` value; if the override was previously unset, clear it with `flutter config --jdk-dir=""`.
- No application data flow, schema migration, or deployment changes are involved. No open decisions remain for correcting this command.
