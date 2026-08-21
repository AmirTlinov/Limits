#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Limits.xcodeproj")
PROJECT_OBJECT_VERSION = 46
PREFERRED_PROJECT_OBJECT_VERSION = "77"
PACKAGE_RESOLVED_PATH = File.join(PROJECT_PATH, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
package_resolved = File.binread(PACKAGE_RESOLVED_PATH) if File.file?(PACKAGE_RESOLVED_PATH)
existing_sources = if File.directory?(PROJECT_PATH)
                     existing_project = Xcodeproj::Project.open(PROJECT_PATH)
                     existing_project.targets.to_h do |target|
                       sources = target.source_build_phase.files.each_with_object({}) do |file, result|
                         result[file.file_ref.path] = file.file_ref.uuid if file.file_ref&.path
                       end
                       [target.name, sources]
                     end
                   else
                     {}
                   end
FileUtils.rm_rf(PROJECT_PATH)

module DeterministicProjectUUIDs
  def generate_available_uuid_list(count = 100)
    @limits_uuid_sequence ||= 0
    candidates = Array.new(count + 1) do
      @limits_uuid_sequence += 1
      format("D%023X", @limits_uuid_sequence)
    end
    uniques = candidates - (@generated_uuids + uuids)
    @generated_uuids += uniques
    @available_uuids.concat(uniques)
  end
end

Xcodeproj::Project.prepend(DeterministicProjectUUIDs)
project = Xcodeproj::Project.new(
  PROJECT_PATH,
  false,
  PROJECT_OBJECT_VERSION
)
project.root_object.preferred_project_object_version = PREFERRED_PROJECT_OBJECT_VERSION
project.root_object.attributes["LastSwiftUpdateCheck"] = "2600"
project.root_object.attributes["LastUpgradeCheck"] = "2600"
project.root_object.attributes["TargetAttributes"] = {}

sources_group = project.main_group.new_group("Sources", "Sources")
tests_group = project.main_group.new_group("Tests", "Tests")
config_group = project.main_group.new_group("Config", "Config")
assets_group = project.main_group.new_group("Assets", "Assets")

limits_group = sources_group.new_group("Limits", "Limits")
core_group = sources_group.new_group("LimitsCore", "LimitsCore")
shared_group = sources_group.new_group("LimitsShared", "LimitsShared")
widget_group = sources_group.new_group("LimitsWidgetExtension", "LimitsWidgetExtension")
unit_tests_group = tests_group.new_group("LimitsTests", "LimitsTests")
ui_tests_group = tests_group.new_group("LimitsUITests", "LimitsUITests")

app = project.new_target(:application, "Limits", :osx, "26.0")
core = project.new_target(:framework, "LimitsCore", :osx, "26.0")
shared = project.new_target(:framework, "LimitsShared", :osx, "26.0")
widget = project.new_target(:app_extension, "LimitsWidgetExtension", :osx, "26.0")
unit_tests = project.new_target(:unit_test_bundle, "LimitsTests", :osx, "26.0")
ui_tests = project.new_target(:ui_test_bundle, "LimitsUITests", :osx, "26.0")

# xcodeproj resolves Cocoa.framework through the active Xcode SDK. Point the
# reference at SDKROOT so Xcode 26 patch releases serialize the same project.
cocoa_framework = project.files.find { |reference| reference.name == "Cocoa.framework" }
raise "Cocoa.framework reference is missing" unless cocoa_framework

cocoa_framework.source_tree = "SDKROOT"
cocoa_framework.path = "System/Library/Frameworks/Cocoa.framework"

sqlite_library = project.frameworks_group.new_file("usr/lib/libsqlite3.tbd")
sqlite_library.source_tree = "SDKROOT"

def enqueue_uuid(project, key)
  uuid = "F#{Digest::SHA256.hexdigest(key).upcase[0, 23]}"
  project.generated_uuids << uuid unless project.generated_uuids.include?(uuid)
  project.instance_variable_get(:@available_uuids).unshift(uuid)
end

def add_swift_source(target, group, source_root, absolute_path, stable_uuid: false)
  relative_to_group = absolute_path.delete_prefix(File.join(ROOT, source_root, "/"))
  enqueue_uuid(target.project, "source-reference:#{target.name}:#{relative_to_group}") if stable_uuid
  reference = group.new_file(relative_to_group)
  enqueue_uuid(target.project, "source-build-file:#{target.name}:#{relative_to_group}") if stable_uuid
  target.source_build_phase.add_file_reference(reference)
end

def add_swift_sources(target, group, relative_glob, existing_sources, deferred_sources)
  source_root = relative_glob.split("/**").first
  paths = Dir.glob(File.join(ROOT, relative_glob)).sort
  known_sources = existing_sources[target.name]
  unless known_sources
    paths.each { |path| add_swift_source(target, group, source_root, path) }
    return
  end

  existing, added = paths.partition do |absolute_path|
    relative_path = absolute_path.delete_prefix(File.join(ROOT, source_root, "/"))
    known_sources.fetch(relative_path, "").start_with?("D")
  end
  existing.each { |path| add_swift_source(target, group, source_root, path) }
  deferred_sources << [target, group, source_root, added]
end

deferred_sources = []
add_swift_sources(app, limits_group, "Sources/Limits/**/*.swift", existing_sources, deferred_sources)
add_swift_sources(core, core_group, "Sources/LimitsCore/**/*.swift", existing_sources, deferred_sources)
add_swift_sources(shared, shared_group, "Sources/LimitsShared/**/*.swift", existing_sources, deferred_sources)
add_swift_sources(widget, widget_group, "Sources/LimitsWidgetExtension/**/*.swift", existing_sources, deferred_sources)
add_swift_sources(unit_tests, unit_tests_group, "Tests/LimitsTests/**/*.swift", existing_sources, deferred_sources)
add_swift_sources(ui_tests, ui_tests_group, "Tests/LimitsUITests/**/*.swift", existing_sources, deferred_sources)

resources_group = shared_group.new_group("Resources", "Resources")
localizable = resources_group.new_variant_group("Localizable.strings")
%w[en es fr ru zh-Hans].each do |language|
  reference = localizable.new_file("#{language}.lproj/Localizable.strings")
  reference.name = language
end
shared.resources_build_phase.add_file_reference(localizable)

app_resources_group = limits_group.new_group("Resources", "Resources")
tray_icons_group = app_resources_group.new_group("TrayIcons", "TrayIcons")
Dir.glob(File.join(ROOT, "Sources/Limits/Resources/TrayIcons/*")).sort.each do |path|
  reference = tray_icons_group.new_file(File.basename(path))
  app.resources_build_phase.add_file_reference(reference)
end

icon_reference = assets_group.new_file("AppIcon.icns")
app.resources_build_phase.add_file_reference(icon_reference)

%w[Limits-Info.plist LimitsWidgetExtension-Info.plist Limits.entitlements LimitsWidgetExtension.entitlements].each do |name|
  config_group.new_file(name)
end

app.add_dependency(shared)
app.add_dependency(core)
app.add_dependency(widget)
core.add_dependency(shared)
widget.add_dependency(shared)
unit_tests.add_dependency(core)
unit_tests.add_dependency(shared)
ui_tests.add_dependency(app)
ui_tests.add_dependency(core)
ui_tests.add_dependency(shared)

app.frameworks_build_phase.add_file_reference(shared.product_reference)
app.frameworks_build_phase.add_file_reference(core.product_reference)
core.frameworks_build_phase.add_file_reference(shared.product_reference)
core.frameworks_build_phase.add_file_reference(sqlite_library)
widget.frameworks_build_phase.add_file_reference(shared.product_reference)
unit_tests.frameworks_build_phase.add_file_reference(core.product_reference)
unit_tests.frameworks_build_phase.add_file_reference(shared.product_reference)
ui_tests.frameworks_build_phase.add_file_reference(core.product_reference)
ui_tests.frameworks_build_phase.add_file_reference(shared.product_reference)

embed_frameworks = app.new_copy_files_build_phase("Embed Frameworks")
embed_frameworks.dst_subfolder_spec = "10"
shared_build_file = embed_frameworks.add_file_reference(shared.product_reference)
shared_build_file.settings = { "ATTRIBUTES" => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
core_build_file = embed_frameworks.add_file_reference(core.product_reference)
core_build_file.settings = { "ATTRIBUTES" => %w[CodeSignOnCopy RemoveHeadersOnCopy] }

embed_extensions = app.new_copy_files_build_phase("Embed App Extensions")
embed_extensions.dst_subfolder_spec = "13"
widget_build_file = embed_extensions.add_file_reference(widget.product_reference)
widget_build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

common_settings = {
  "ARCHS" => "arm64",
  "CLANG_ENABLE_MODULES" => "YES",
  "CODE_SIGN_STYLE" => "Automatic",
  "DEVELOPMENT_TEAM" => "M94V58FCVP",
  "LIMITS_APP_GROUP_ID" => "M94V58FCVP.com.amir.Limits.shared",
  "MACOSX_DEPLOYMENT_TARGET" => "26.0",
  "SWIFT_STRICT_CONCURRENCY" => "complete",
  "SWIFT_VERSION" => "6.0"
}

project.build_configurations.each do |configuration|
  configuration.build_settings.merge!(common_settings)
  configuration.build_settings["ONLY_ACTIVE_ARCH"] = "YES" if configuration.name == "Debug"
end

targets = [app, core, shared, widget, unit_tests, ui_tests]
targets.each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(common_settings)
  end
end

app.build_configurations.each do |configuration|
  bundle_identifier = configuration.name == "Debug" ? "com.amir.Limits.TestHost" : "com.amir.Limits"
  app_group_identifier = configuration.name == "Debug" ? "M94V58FCVP.com.amir.Limits.test.shared" : "M94V58FCVP.com.amir.Limits.shared"
  configuration.build_settings.merge!(
    "CODE_SIGN_ENTITLEMENTS" => "Config/Limits.entitlements",
    "CURRENT_PROJECT_VERSION" => "1",
    "ENABLE_HARDENED_RUNTIME" => "YES",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "Config/Limits-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../Frameworks",
    "MARKETING_VERSION" => "1.0.0",
    "LIMITS_APP_GROUP_ID" => app_group_identifier,
    "PRODUCT_BUNDLE_IDENTIFIER" => bundle_identifier,
    "PRODUCT_NAME" => "Limits"
  )
end

shared.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "DEFINES_MODULE" => "YES",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.Shared",
    "SKIP_INSTALL" => "YES"
  )
end

core.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
    "DEFINES_MODULE" => "YES",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.Core",
    "SKIP_INSTALL" => "YES"
  )
end

widget.build_configurations.each do |configuration|
  bundle_identifier = configuration.name == "Debug" ? "com.amir.Limits.TestHost.WidgetExtension" : "com.amir.Limits.WidgetExtension"
  app_group_identifier = configuration.name == "Debug" ? "M94V58FCVP.com.amir.Limits.test.shared" : "M94V58FCVP.com.amir.Limits.shared"
  configuration.build_settings.merge!(
    "APPLICATION_EXTENSION_API_ONLY" => "YES",
    "CODE_SIGN_ENTITLEMENTS" => "Config/LimitsWidgetExtension.entitlements",
    "CURRENT_PROJECT_VERSION" => "1",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "Config/LimitsWidgetExtension-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../../../../Frameworks",
    "MARKETING_VERSION" => "1.0.0",
    "LIMITS_APP_GROUP_ID" => app_group_identifier,
    "PRODUCT_BUNDLE_IDENTIFIER" => bundle_identifier,
    "SKIP_INSTALL" => "YES"
  )
end

unit_tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "GENERATE_INFOPLIST_FILE" => "YES",
    "INFOPLIST_KEY_LimitsAppGroupIdentifier" => "M94V58FCVP.com.amir.Limits.test.shared",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.CoreTests"
  )
end

ui_tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "GENERATE_INFOPLIST_FILE" => "YES",
    "INFOPLIST_KEY_LimitsAppGroupIdentifier" => "M94V58FCVP.com.amir.Limits.test.shared",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.UITests",
    "TEST_TARGET_NAME" => "Limits"
  )
end

sparkle_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle_package.repositoryURL = "https://github.com/sparkle-project/Sparkle"
sparkle_package.requirement = { "kind" => "exactVersion", "version" => "2.9.6" }
project.root_object.package_references << sparkle_package

sparkle_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
sparkle_product.package = sparkle_package
sparkle_product.product_name = "Sparkle"
app.package_product_dependencies << sparkle_product

sparkle_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
sparkle_build_file.product_ref = sparkle_product
app.frameworks_build_phase.files << sparkle_build_file

deferred_sources.each do |target, group, source_root, paths|
  paths.each { |path| add_swift_source(target, group, source_root, path, stable_uuid: true) }
end

project.root_object.attributes["TargetAttributes"] = targets.to_h do |target|
  [target.uuid, { "CreatedOnToolsVersion" => "26.0", "DevelopmentTeam" => "M94V58FCVP", "ProvisioningStyle" => "Automatic" }]
end

project.sort
project.save

if package_resolved
  FileUtils.mkdir_p(File.dirname(PACKAGE_RESOLVED_PATH))
  File.binwrite(PACKAGE_RESOLVED_PATH, package_resolved)
end

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, unit_tests, launch_target: app)
scheme.add_test_target(ui_tests)
scheme.save_as(PROJECT_PATH, "Limits", true)

puts PROJECT_PATH
