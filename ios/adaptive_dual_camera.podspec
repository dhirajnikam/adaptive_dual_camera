#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint adaptive_dual_camera.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'adaptive_dual_camera'
  s.version          = '0.0.1'
  s.summary          = 'Front and back photos and video behind one API.'
  s.description      = <<-DESC
Front and back photo and video capture behind one API - simultaneously via
AVCaptureMultiCamSession where the hardware allows it, sequentially everywhere
else, with a customisable dual preview.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'adaptive_dual_camera/Sources/adaptive_dual_camera/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'adaptive_dual_camera_privacy' => ['adaptive_dual_camera/Sources/adaptive_dual_camera/PrivacyInfo.xcprivacy']}
end
