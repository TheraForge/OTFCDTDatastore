# OTFCDTDatastore

OTFCDTDatastore provides Cloudant Sync to store, index and query local JSON data on a device and to synchronise data between many devices. For more details about the OTFCDTDatastore please refer to the [CDTDatastore docs](https://github.com/cloudant/CDTDatastore#cdtdatastore).

Please refer to the top-level parent framework: [OTFToolBox](https://github.com/TheraForge/OTFToolBox)

## Change Log
<details open>
  <summary>Release 1.0.3-beta</summary>
  <ul>
    <li>Added Watch OS support</li>
  </ul>
</details>

## Table of contents
* [Overview](#overview)
* [Installation](#installation)
* [File Protection](#file-protection-levels)
* [Usage](#usage)
* [License](#license)


## Overview <a name="overview"></a>
**The Theraforge OTFCDTDatastore provides File protection for your application along with the basic cloudant OTFCDTDatastore functionalities. The different types of file protection levels that you can apply on your files before starting and after finishing operations on the files.**

## Installation <a name="installation"></a>

* [Prerequisites](#prerequisites)
* [Project Setup](#project-setup)

### Prerequisites <a name="prerequisites"></a>

An Intel-based Mac running [macOS Catalina 10.15.4 or later](https://developer.apple.com/documentation/xcode-release-notes/xcode-12-release-notes).

Install the following components:

* Xcode 12 or later (SDK 14)

* CocoaPods 1.10.0 or later

For your projects make sure to target iOS 13 or later

### Project Setup <a name="project-setup"></a>

If you don't have Xcode, then follow this [Xcode article](https://medium.nextlevelswift.com/install-and-configure-xcode-7ed0c5592219) to install and configure Xcode.

After successfully installing Xcode and creating a new project, you can build your first digital health application.

The next step is to integrate OTFCDTDatastore with your application. OTFCDTDatastore can be installed via CocoaPods.

If you are new to CocoaPods you can refer to the [CocoaPods Guides](https://guides.cocoapods.org/using/using-cocoapods.html) to learn more about it.

CocoaPods is built with the Ruby language and can be installed with the default version of Ruby available with macOS.

Integrating OTFCDTDatastore with an existing workspace requires the below extra line in your Podfile.

Add pod 'OTFCDTDatastore' under target in Podfile.


``` 
pod 'OTFCDTDatastore'
```

Run pod install from the terminal root of your project directory, which will fetch all the external dependencies mentioned by you, and associate it with a .xcworkspace file of your project. This .xcworkspace file will be generated for you if you already do not have one.

``` 
$ pod install
```

Once you successfully install podspec, you can start importing OTFCDTDatastore.

## File Protection Levels <a name="file-protection-levels"></a>

There are different types of File protections available in iOS categorised by the key [NSFileProtectionType](https://developer.apple.com/documentation/foundation/nsfileprotectiontype). Using these file protections types in CDTDatastore framework Theraforge provides three types of Protection modes on the files that will help to set encryption with different behaviours. Setting any mode will ensure the file protection that you want to apply on your files before starting and after finishing any operation on the files. 

* mode1 - In this mode application is guaranteed to complete synchronization within 10 seconds. After 10 seconds application will not be able to access the files in the background.

* mode2 - In this mode application needs 20 seconds time for the synchronization. After 20 seconds application will not be able to access the files in the background.

* background - In this mode application need to periodically run in the background. It will give 30 seconds time frame to finish any operation in the background. After 30 seconds application will not be able to access the files.

## Usage <a name="usage"></a>
To access OTF protection levels in your existing application install [Theraforge CDTDatastore](#Installation) and then use below functions with the help of CDTDatastore object.


```
/// Call encryption function with the help of datastore object in OBJECTIVE C
# -(void)setProtectionLevel: (OTFProtectionLevel)level;'

/// Replace mode1 with any other available mode.
# [datastore setProtectionLevel: mode1];
```


```
/// Call encryption function with the help of datastore object in SWIFT -
# dataStore.setProtectionLevel(.level)

```

## License <a name="license"></a>

This project is made available under the terms of an APACHE license. See the [LICENSE](LICENSE) file.
