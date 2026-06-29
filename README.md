# Flutter for webOS

Flutter-webOS is an extension to the Flutter SDK for developing Flutter applications for webOS. 

It provides the necessary tools and libraries to build, package, and run Flutter apps on webOS-powered devices.


## Quick Start 

```
flutter-webos doctor -v
flutter-webos precache -f
flutter-webos devices 

flutter-webos create --platforms webos helloworld
helloworld$ flutter-webos build webos --release
helloworld$ flutter-webos run -d <your_device_id>
```

For detailed installation steps, please refer to the instructions below.

## Required Installations

[Getting Started with Flutter for webOS](./doc/getting-started.md)
- Flutter-webOS CLI
- Flutter-webOS SDK
- webOS NDK

## License
This project is licensed under the [LICENSE](./LICENSE) file.

