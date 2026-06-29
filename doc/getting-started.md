# Getting Started with Flutter for webOS

flutter-webos is an extension to the Flutter SDK that enables the development of Flutter applications for webOS using the Flutter framework. It provides all the necessary tools and libraries to build, package, and run Flutter apps on webOS-based devices. This document provides guidance on how to set up the environment to create, build, and run a Flutter app on webOS TV using the flutter-webos toolchain.

> If you encounter any issues, please create a ticket on the Partner Zone or contact us via email at **DL-Flutter-SDK@lge.com**.

## Requirements

### Host Environment

Flutter for webOS development is supported on **Linux (Ubuntu)** only.

| Ubuntu Version | Codename |
|----------------|----------|
| 22.04.3 LTS | Jammy Jellyfish |
| 24.04 LTS | Noble Numbat |
| 26.04 LTS | Resolute Raccoon |

> Only Ubuntu environments are officially supported. If you are using macOS or Windows, use **WSL2** (Windows Subsystem for Linux) or a **Docker-based DevContainer** to set up a compatible Ubuntu environment.

### Target Device

Flutter for webOS supports webOS TV starting at **webOS 26 Re:New**. Developer Mode must be enabled on the TV before deploying apps.

## Set up the environment

This section covers the initial setup required for your development machine. Setting up your environment involves three stages: installing system-level dependencies, installing the flutter-webOS SDK and NDK, and verifying the installation.

### 1. Set up the Linux environment

Ensure your Git version is **2.23 or higher**, then configure your global Git user settings.

```bash
git --version
# Example output: git version 2.49.0

git config --global user.name "{Your Name}"
git config --global user.email "{Your Email}"
```

Install the necessary packages for development.

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install curl unzip cmake pkg-config file libgtk-3-0 libgtk-3-dev git ninja-build clang git-lfs -y
```

### 2. Install the flutter-webOS SDK

Clone the SDK repository, then set the flutter-webOS SDK path, engine base URL, and webOS NDK. You must re-run the following `export` commands every time you start a new terminal session.

#### Step 1: Clone the SDK Repository

```bash
git clone https://github.com/lg-flutter-webos/flutter-webos.git
```

#### Step 2: Set the flutter-webOS SDK path

```bash
cd flutter-webos
export PATH="$PATH:$(pwd)/bin"
```

#### Step 3: (Optional) Override the Engine Base URL

flutter-webos downloads the Flutter engine binaries during the build process. By default it fetches them from the public release host, so no setup is required. Set this variable only if you need to point at a different release source.

```bash
export WEBOS_ENGINE_BASE_URL="https://github.com/lg-flutter-webos/artifacts/releases/download"
```

#### Step 4: Install webOS CLI

The webOS CLI (ares) is required for deploying and managing apps on webOS devices. Install **Node.js first**, then the webOS CLI — installing in this order prevents potential dependency errors.

1. Install **Node.js** version **14.15.1 – 16.20.2** (required by ares).
2. Install **webOS CLI (ares)** from: [webOS TV CLI Installation Guide](https://webostv.developer.lge.com/develop/tools/cli-installation)
3. **ares >= 3.2.4** is required. You can verify the installed version with `flutter-webos doctor -v`. If the version is below 3.2.4, the SDK will report a failure.

#### Step 5: Install and set the path for webOS NDK

The webOS NDK (Native Development Kit) provides the cross-compilation toolchain needed to build Flutter apps for webOS TV.

Download and run the NDK installer:

```bash
mkdir -p NDK
cd NDK
wget https://github.com/lg-flutter-webos/ndk/releases/download/11.2.0/webos-ndk-flutter-starfish-x86_64-ca9v1-11.2.0.sh
./webos-ndk-flutter-starfish-x86_64-ca9v1-11.2.0.sh -y
```

Specify the path for the NDK environment setup script:

```bash
export WEBOS_FLUTTER_NDK_ENV="/usr/local/starfish-sdk-x86_64/environment-setup-ca9v1-webosmllib32-linux-gnueabi"
```

Each time you wish to use the SDK in a new shell session, you need to source the environment setup script:

```bash
. /usr/local/starfish-sdk-x86_64/environment-setup-ca9v1-webosmllib32-linux-gnueabi
```

#### Step 6: Pre-cache Engine Artifacts

`flutter-webos precache` downloads the webOS engine binaries to your local cache in advance, so that subsequent `flutter-webos build` commands do not need to fetch them from the network each time.

```bash
flutter-webos precache
```

### 3. Verify Installation

Run the following commands to confirm all components are configured correctly.

**Check Version:**

```bash
flutter-webos --version
```

Example output:
```
Flutter 3.38.10 • webOS artifacts 1
Framework • revision c6f67dede3 • 2026-02-10 11:05:04 -0800
Engine • revision cafcda5721
Tools • Dart 3.10.9 • DevTools 2.51.1
Tools • flutter-webos revision (d2d4256)
```

**Run Doctor:**

```bash
flutter-webos doctor -v
```

For webOS development, the following three items must show `[✓]`:

```
[✓] Flutter
[✓] webOS toolchain - develop for webOS
[✓] Linux toolchain - develop for Linux desktop
```

> The `webOS toolchain` section also displays the NDK `DISTRO_VERSION`. Other items such as Android toolchain, Chrome, or Android Studio are not required for webOS development and can be ignored.

## Device Setup

This section covers how to connect your webOS TV as a development target. Once your SDK is ready, you need to enable Developer Mode on the TV and register it so that flutter-webos can deploy and communicate with the device over the network.

### 1. Enable Developer Mode on the TV

1. Enable **Developer Mode** on your webOS TV.
2. Turn on the **Key Server**.
3. Note your **Passphrase**.

For details, see the [webOS Developer Guide](https://webostv.developer.lge.com/develop/tools/webos-studio-dev-guide#webos-studio-developer-guide).

### 2. Add the Device

**Step 1:** Enable the custom devices feature.

```bash
flutter-webos config --enable-custom-devices
```

**Step 2:** Register your webOS TV by entering its ID, IP address, and port.

```bash
flutter-webos custom-devices add
```

Follow the prompts as shown in the example below:

```
Please enter the unique id you want to device to have. Must contain only alphanumeric or underscore characters.
(example: webos)
myTV
Please enter the hostname or IPv4 address of the device.
(example: 192.168.0.100)
192.168.0.100
Please enter the port number for ssh connection.
(example: 9922, empty for 9922)
9922
Would you like to add the custom device to the config now? [Y/n] (empty for default)
Y
```

> The default port is `9922` (Developer Mode SSH).


**Step 3:** Retrieve the SSH key from your TV using your Passphrase.

```bash
flutter-webos custom-devices get-key -d <your_device_id>
# You will be prompted for the passphrase from Developer Mode.
```

### 3. Verify the Connection

Confirm that the device is listed and reachable:

```bash
flutter-webos devices
```

### 4. Managing Devices

After initial registration, you can manage your custom devices using the following subcommands.

| Subcommand | Description |
|------------|-------------|
| `flutter-webos custom-devices list` | List all configured custom devices, both enabled and disabled. |
| `flutter-webos custom-devices delete` | Remove a device from the config file. |
| `flutter-webos custom-devices get-key` | Retrieve the RSA key from the device and save it to the config file. |
| `flutter-webos custom-devices reset` | Reset the custom devices config file to its default state. |

## Develop an App

Once your environment is ready, the development workflow consists of creating a project, building an installable `.ipk` package, and running it on your TV.

### 1. Create a Project

Create a new project with webOS platform support using `flutter-webos create`.

```bash
flutter-webos create --platforms webos helloworld
```

### 2. Build and Package

Navigate to your project directory and build an installable `.ipk` package. The IPK file is always generated automatically during the build — no additional flags are needed. Choose the build mode based on your intent.

```bash
cd helloworld

flutter-webos clean  # optional — run only when the build cache is corrupted or after significant dependency changes

flutter-webos build webos --debug     # development — includes debug symbols
flutter-webos build webos --profile   # performance profiling
flutter-webos build webos --release   # production release
```

The `.ipk` file will be generated at:

```
build/webos/{arch}/{mode}/ipk/{id}_{version}_{arch}.ipk
```

For example, a debug build produces:

```
build/webos/arm/debug/ipk/com.flutter.app.helloworld_1.0.0_arm.ipk
```

### 3. Install and Run the App

Deploy the app to your registered device with `flutter-webos run`. Once the command runs successfully, the app will be installed and launched automatically on your webOS TV. The `run` command performs the build and IPK packaging automatically, so you can go directly from source to device with a single command.

```bash
flutter-webos run -d <your_device_id> --debug    # development
flutter-webos run -d <your_device_id> --profile  # performance profiling
flutter-webos run -d <your_device_id> --release  # production release
```

> When you press `q` to quit, the app on the device is also terminated. In previous versions, the app remained running after the tool exited.

To uninstall the app from the device:

```bash
flutter-webos install --uninstall-only -d <your_device_id>
```

### 4. Debugging

Run the app in debug mode using the `--debug` flag.

```bash
flutter-webos run --debug -d <your_device_id>
```

A successful launch will show output like this:

```
Launching lib/main.dart on webOS in debug mode...
Syncing files to device webOS...

Flutter run key commands:
r Hot reload.
R Hot restart.
d Detach (terminate "flutter-webos run" but leave the application running).
h List all available interactive commands.
q Quit (terminate the application on the device).

A Dart VM Service on webOS is available at: http://127.0.0.1:<port>/<token>/
The Flutter DevTools debugger and profiler on webOS is available at: http://127.0.0.1:<port>/
```

Open the **Dart VM Service URL** or the **Flutter DevTools URL** from the output in your browser to inspect and debug your app.

In `--debug` mode, you can use the **detach/attach** feature:
- Press `d` to detach from the running app without stopping it.
- Use `flutter-webos attach -d <your_device_id>` to reattach to the running app and resume debugging.

### 5. Run on Linux (Optional)

If you created the project with Linux support, you can build and run the app on your desktop without a physical webOS device. This is useful for quickly verifying UI during development.

```bash
flutter-webos create --platforms webos,linux helloworld

flutter-webos build linux
flutter-webos run -d linux
```

## Configuration

### flutter-conf.json

The `flutter-conf.json` file is located at `webos/meta/flutter-conf.json` in your project. It controls runtime configuration for the app on the webOS device.

#### Impeller Rendering Engine

By default, the Skia rendering backend is used. To enable the Impeller rendering engine, set `"enable-impeller"` to `true` in `flutter-conf.json`:

```json
{
  "FLUTTER_HOME": "",
  "FLUTTER_TEMP_HOME": ".cache",
  "FLUTTER_APPDATA_HOME": ".data",
  "FLUTTER_DOWNLOAD_HOME": ".download",
  "FLUTTER_EXT_STORAGE_PATH": "",
  "FLUTTER_APP_LOG_PATH": "log",
  "engine-switches": {
    "enable-impeller": true
  }
}
```

## Plugins

flutter-webos provides a set of webOS-specific plugins, each targeting a specific area of the webOS platform. For detailed usage of each plugin, refer to the plugin documentation.

Available plugins are listed in the [plugins repository](https://github.com/lg-flutter-webos/plugins).

## ACG (Access Control Group)

webOS TV enforces access control on all Luna Service API calls through **ACG**. Each Luna Service method belongs to one or more ACG groups, and your app must be granted access to the relevant groups before it can call those APIs. Without the correct ACG setup, Luna Service calls will be rejected at runtime regardless of the implementation.

When building your Flutter app with `flutter-webos build`, the default ACG permissions required for basic app functionality are automatically included in the package. If your app needs to call additional Luna Service APIs beyond the defaults, you must declare the required ACG groups in your app's configuration.

To use Luna Service APIs in your Flutter app, you need to declare the required ACG groups in your app's configuration. The ACG configuration files must be included in the webOS project structure before building.

**Step 1:** Identify the ACG group required for the Luna Service API you want to call. You can find the ACG group information in the ACG Guide.

**Step 2:** Declare the required ACG groups in your app's permission configuration. The following example requests access to the `config` group:

```json
{
  "com.example.myapp": ["config"]
}
```

**Step 3:** Call the Luna Service API using [`webos_service_bridge`](https://github.com/lg-flutter-webos/plugins/tree/main/packages/webos_service_bridge).

> ACG configuration is automatically installed to the correct system paths during `flutter-webos build`. You do not need to copy or place files manually.
