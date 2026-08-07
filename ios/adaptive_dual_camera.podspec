Pod::Spec.new do |s|
  s.name             = 'adaptive_dual_camera'
  s.version          = '0.5.0'
  s.summary          = 'Concurrent-camera capability probe for adaptive_dual_camera.'
  s.description      = <<-DESC
Reports whether the device can run the front and back cameras at the same
time (AVCaptureMultiCamSession). Capture itself is pure Dart on top of the
official camera plugin.
                       DESC
  s.homepage         = 'https://github.com/dhirajnikam/adaptive_dual_camera'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dhiraj Nikam' => 'https://github.com/dhirajnikam' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
