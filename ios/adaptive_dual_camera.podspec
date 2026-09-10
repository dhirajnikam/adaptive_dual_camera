Pod::Spec.new do |s|
  s.name             = 'adaptive_dual_camera'
  s.version          = '0.8.0'
  s.summary          = 'Simultaneous front + back capture for adaptive_dual_camera.'
  s.description      = <<-DESC
The package's only native code: reports whether the device can run the front
and back cameras at once (AVCaptureMultiCamSession, A12 / iOS 13+), and runs
that concurrent session — two preview textures, two JPEGs fired together.
Sequential capture and the composed layout are pure Dart.
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
