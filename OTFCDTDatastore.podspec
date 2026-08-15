license = <<EOT
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
EOT

Pod::Spec.new do |s|
  s.name         = "OTFCDTDatastore"
  s.version      = "2.1.1-tf.3"
  s.summary      = "OTFCDTDatastore is a document datastore which syncs between many devices."
  s.description  = <<-DESC
                      OTFCDTDatastore provides Cloudant Sync to store, index and query local JSON data on a device and to synchronise data between many devices.
                   DESC
  s.homepage     = "https://github.com/TheraForge/OTFCDTDatastore"
  s.license      = {:type => 'Apache, Version 2.0', :text => license}
  s.author       = { 'Hippocrates Technologies' => 'hippocratestech-dev@googlegroups.com' }
  s.source       = { :git => "https://github.com/TheraForge/OTFCDTDatastore.git", :tag => s.version.to_s }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '10.9'
  s.watchos.deployment_target = '9.0'
  s.requires_arc = true

  s.default_subspec = 'standard'

  ['standard', 'SQLCipher'].each do |subspec_label|
      s.subspec subspec_label do |sp|

        sp.prefix_header_contents = '#import "CollectionUtils.h"', '#import "Logging.h"', '#import "Test.h"', '#import "CDTMacros.h"'
        sp.private_header_files = 'OTFCDTDatastore/touchdb/*.h'

        sp.source_files = 'OTFCDTDatastore/**/*.{h,m}'

        sp.exclude_files = 'OTFCDTDatastore/vendor/MYUtilities/*.{h,m}'

        sp.dependency 'OTFCDTDatastore/common-dependencies'

        if subspec_label == 'standard'
          sp.library = 'sqlite3', 'z'
        else
          sp.xcconfig = { 'OTHER_CFLAGS' => '$(inherited) -DENCRYPT_DATABASE' }
          sp.library = 'z'
          # Some CDTDatastore classes use SQLite functions, therefore we have
          # to include 'SQLCipher' although 'FMDB/SQLCipher' also depends on it
          # or they will not compile (linker will not find some symbols).
          # Also, we have to force cocoapods to configure SQLCipher with support
          # for FTS.
          sp.dependency 'SQLCipher/fts', '~> 3.1.0'
        end
    end
  end

  s.subspec 'common-dependencies' do |sp|
    sp.dependency 'OTFCDTDatastore/no-arc'
    sp.ios.dependency 'OTFToolBoxCore', '2.5.0'
    sp.watchos.dependency 'OTFToolBoxCore', '2.5.0'
  end

  s.subspec 'no-arc' do |sp|
    sp.requires_arc = false

    sp.prefix_header_contents = '#import "CollectionUtils.h"', '#import "Logging.h"', '#import "Test.h"'

    sp.source_files = 'OTFCDTDatastore/vendor/MYUtilities/*.{h,m}'
    sp.ios.exclude_files = 'OTFCDTDatastore/vendor/MYUtilities/MYURLHandler.{h,m}'
    sp.watchos.exclude_files = 'OTFCDTDatastore/vendor/MYUtilities/MYURLHandler.{h,m}'
  end
end
