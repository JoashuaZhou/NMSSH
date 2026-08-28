Pod::Spec.new do |spec|
  spec.name         = "NMSSH"
  spec.version      = "2.4.1"
  spec.summary      = "NMSSH is a clean, easy-to-use, unit tested framework for iOS and OSX that wraps libssh2."
  spec.homepage     = "https://github.com/NMSSH/NMSSH"
  spec.license      = 'MIT'
  spec.authors      = { "Christoffer Lejdborg" => "hello@9muses.se", "Tommaso Madonia" => "tommaso@madonia.me" }

  spec.source       = { :git => "https://github.com/JoashuaZhou/NMSSH.git", :tag => spec.version.to_s }

  spec.requires_arc = true
  spec.platform = :ios
  spec.platform = :osx

  spec.source_files = 'NMSSH', 'NMSSH/**/*.{h,m}'
  spec.public_header_files  = 'NMSSH/*.h', 'NMSSH/Protocols/*.h', 'NMSSH/Config/NMSSHLogger.h'
  spec.private_header_files = 'NMSSH/Config/NMSSH+Protected.h', 'NMSSH/Config/socket_helper.h'
  spec.libraries    = 'z'
  spec.framework    = 'CFNetwork'

  spec.ios.deployment_target  = '13.0'
  # 真机切片(arm64/arm64e)来自原 fat .a，未改动；模拟器切片(arm64/x86_64)由同版本源码
  # (libssh2 1.9.0 + OpenSSL 1.1.1w) 针对 iphonesimulator SDK 编译，使 NMSSH 可在模拟器上完整运行。
  spec.ios.vendored_frameworks = 'NMSSH-iOS/Libraries/lib/libssh2.xcframework', 'NMSSH-iOS/Libraries/lib/libssl.xcframework', 'NMSSH-iOS/Libraries/lib/libcrypto.xcframework'
  spec.ios.source_files       = 'NMSSH-iOS', 'NMSSH-iOS/Libraries/**/*.h'
  spec.ios.public_header_files  = 'NMSSH-iOS/Libraries/**/*.h'

  spec.osx.deployment_target  = '10.8'
  spec.osx.vendored_libraries = 'NMSSH-OSX/Libraries/lib/libssh2.a', 'NMSSH-OSX/Libraries/lib/libssl.a', 'NMSSH-OSX/Libraries/lib/libcrypto.a'
  spec.osx.source_files       = 'NMSSH-OSX', 'NMSSH-OSX/Libraries/**/*.h'
  spec.osx.public_header_files  = 'NMSSH-OSX/Libraries/**/*.h'

  spec.resource_bundles = {
    'NMSSHPrivacy' => ['NMSSH/PrivacyInfo.xcprivacy'],
  }

  spec.xcconfig = {
    "OTHER_LDFLAGS" => "-ObjC",
  }

end
