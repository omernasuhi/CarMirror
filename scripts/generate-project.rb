# CarMirror.xcodeproj dosyasını kaynak klasörlerden yeniden üretir.
# Dosya ekleyip çıkardıktan sonra çalıştırın:
#
#   gem install xcodeproj
#   ruby scripts/generate-project.rb
#
# Xcode'da elle yapılan proje değişiklikleri bu betik çalışınca kaybolur.

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'CarMirror.xcodeproj')
DEPLOYMENT_TARGET = '17.0'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH, false, 56)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'
project.root_object.attributes['LastUpgradeCheck'] = '2600'
project.root_object.development_region = 'tr'
project.root_object.known_regions = %w[tr Base]

project.build_configurations.each do |config|
  s = config.build_settings
  # Kendi cihazınızda çalıştırmak için bunu kendi ters alan adınızla değiştirin.
  s['BUNDLE_ID_PREFIX'] = 'com.omernasuhi'
  s['APP_GROUP_ID'] = 'group.$(BUNDLE_ID_PREFIX).carmirror'
  # Gerçek cihazda CarPlay yetkisi (com.apple.developer.carplay-maps) Apple onayı
  # gerektirir; onay yokken imzalama hata vermesin diye cihaz derlemesi bu yetki
  # olmadan imzalanır. Apple onaylayınca 'App/CarMirror.entitlements' yapın.
  s['CARMIRROR_DEVICE_ENTITLEMENTS'] = 'App/CarMirror-NoCarPlay.entitlements'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SDKROOT'] = 'iphoneos'
  s['SWIFT_VERSION'] = '5.0'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
end

app = project.new_target(:application, 'CarMirror', :ios, DEPLOYMENT_TARGET, nil, :swift)
ext = project.new_target(:app_extension, 'BroadcastExtension', :ios, DEPLOYMENT_TARGET, nil, :swift)
tests = project.new_target(:unit_test_bundle, 'CarMirrorTests', :ios, DEPLOYMENT_TARGET, nil, :swift)

# Xcodeproj eski projeler için Foundation.framework ekliyor; Swift'te gereksiz.
[app, ext, tests].each do |target|
  target.frameworks_build_phase.files.dup.each(&:remove_from_project)
end
project.frameworks_group.recursive_children.select { |c| c.isa == 'PBXFileReference' }.each(&:remove_from_project)
project.frameworks_group.remove_from_project

def add_folder(project, path, &block)
  group = project.main_group.find_subpath(path, true)
  group.set_source_tree('<group>')
  group.set_path(File.basename(path))
  Dir.children(File.join(ROOT, path)).sort.each do |name|
    next if name.start_with?('.')
    ref = group.new_reference(name)
    block.call(ref, File.extname(name))
  end
end

add_folder(project, 'App') do |ref, ext_name|
  case ext_name
  when '.swift' then app.source_build_phase.add_file_reference(ref)
  when '.xcassets' then app.resources_build_phase.add_file_reference(ref)
  end
end
add_folder(project, 'BroadcastExtension') do |ref, ext_name|
  ext.source_build_phase.add_file_reference(ref) if ext_name == '.swift'
end
add_folder(project, 'Shared') do |ref, ext_name|
  next unless ext_name == '.swift'
  app.source_build_phase.add_file_reference(ref)
  ext.source_build_phase.add_file_reference(ref)
end

tests_group = project.main_group.find_subpath('Tests/CarMirrorTests', true)
project.main_group.find_subpath('Tests', false).set_path('Tests')
tests_group.set_path('CarMirrorTests')
Dir.children(File.join(ROOT, 'Tests/CarMirrorTests')).sort.each do |name|
  next unless name.end_with?('.swift')
  tests.source_build_phase.add_file_reference(tests_group.new_reference(name))
end

project.main_group.new_reference('README.md')

app.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(BUNDLE_ID_PREFIX).carmirror'
  s['INFOPLIST_FILE'] = 'App/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'App/CarMirror.entitlements'
  s['CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'] = '$(CARMIRROR_DEVICE_ENTITLEMENTS)'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
  s.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')
end

ext.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(BUNDLE_ID_PREFIX).carmirror.BroadcastExtension'
  s['INFOPLIST_FILE'] = 'BroadcastExtension/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'BroadcastExtension/BroadcastExtension.entitlements'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
end

tests.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = '$(BUNDLE_ID_PREFIX).carmirror.tests'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/CarMirror.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CarMirror'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
end

app.add_dependency(ext)
embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
embed_file = embed.add_file_reference(ext.product_reference, true)
embed_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

tests.add_dependency(app)

project.save
pbxproj = File.join(PROJECT_PATH, 'project.pbxproj')
File.write(pbxproj, File.read(pbxproj).gsub(/^\s*preferredProjectObjectVersion = \d+;\n/, ''))

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests, launch_target: true)
scheme.test_action.code_coverage_enabled = false
scheme.save_as(PROJECT_PATH, 'CarMirror', true)

puts "Oluşturuldu: #{PROJECT_PATH}"
