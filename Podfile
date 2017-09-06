use_frameworks!
platform :ios, 11.0

target 'try Connect' do
  pod 'BarcodeScanner'
  pod 'SVProgressHUD'
end

post_install do |installer|
    installer.pods_project.targets.each do |target|
        if target.name == 'BarcodeScanner'
            target.build_configurations.each do |config|
                config.build_settings['SWIFT_VERSION'] = '3.2'
            end
        end
    end
end
