#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Limits.xcodeproj")
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
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2600"
project.root_object.attributes["LastUpgradeCheck"] = "2600"
project.root_object.attributes["TargetAttributes"] = {}

sources_group = project.main_group.new_group("Sources", "Sources")
tests_group = project.main_group.new_group("Tests", "Tests")
config_group = project.main_group.new_group("Config", "Config")
assets_group = project.main_group.new_group("Assets", "Assets")

limits_group = sources_group.new_group("Limits", "Limits")
shared_group = sources_group.new_group("LimitsShared", "LimitsShared")
widget_group = sources_group.new_group("LimitsWidgetExtension", "LimitsWidgetExtension")
unit_tests_group = tests_group.new_group("LimitsTests", "LimitsTests")
ui_tests_group = tests_group.new_group("LimitsUITests", "LimitsUITests")

app = project.new_target(:application, "Limits", :osx, "26.0")
shared = project.new_target(:framework, "LimitsShared", :osx, "26.0")
widget = project.new_target(:app_extension, "LimitsWidgetExtension", :osx, "26.0")
unit_tests = project.new_target(:unit_test_bundle, "LimitsTests", :osx, "26.0")
ui_tests = project.new_target(:ui_test_bundle, "LimitsUITests", :osx, "26.0")

def add_swift_sources(target, group, relative_glob)
  source_root = relative_glob.split("/**").first
  Dir.glob(File.join(ROOT, relative_glob)).sort.each do |absolute_path|
    relative_to_group = absolute_path.delete_prefix(File.join(ROOT, source_root, "/"))
    reference = group.new_file(relative_to_group)
    target.source_build_phase.add_file_reference(reference)
  end
end

add_swift_sources(app, limits_group, "Sources/Limits/**/*.swift")
add_swift_sources(shared, shared_group, "Sources/LimitsShared/**/*.swift")
add_swift_sources(widget, widget_group, "Sources/LimitsWidgetExtension/**/*.swift")
add_swift_sources(unit_tests, unit_tests_group, "Tests/LimitsTests/**/*.swift")
add_swift_sources(ui_tests, ui_tests_group, "Tests/LimitsUITests/**/*.swift")

resources_group = limits_group.new_group("Resources", "Resources")
localizable = resources_group.new_variant_group("Localizable.strings")
%w[en es fr ru zh-Hans].each do |language|
  reference = localizable.new_file("#{language}.lproj/Localizable.strings")
  reference.name = language
end
app.resources_build_phase.add_file_reference(localizable)

tray_icons_group = resources_group.new_group("TrayIcons", "TrayIcons")
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
app.add_dependency(widget)
widget.add_dependency(shared)
unit_tests.add_dependency(app)
unit_tests.add_dependency(shared)
ui_tests.add_dependency(app)

app.frameworks_build_phase.add_file_reference(shared.product_reference)
widget.frameworks_build_phase.add_file_reference(shared.product_reference)
unit_tests.frameworks_build_phase.add_file_reference(shared.product_reference)

embed_frameworks = app.new_copy_files_build_phase("Embed Frameworks")
embed_frameworks.dst_subfolder_spec = "10"
shared_build_file = embed_frameworks.add_file_reference(shared.product_reference)
shared_build_file.settings = { "ATTRIBUTES" => %w[CodeSignOnCopy RemoveHeadersOnCopy] }

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

targets = [app, shared, widget, unit_tests, ui_tests]
targets.each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(common_settings)
  end
end

app.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "CODE_SIGN_ENTITLEMENTS" => "Config/Limits.entitlements",
    "CURRENT_PROJECT_VERSION" => "1",
    "ENABLE_HARDENED_RUNTIME" => "YES",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "Config/Limits-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../Frameworks",
    "MARKETING_VERSION" => "1.0.0",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits",
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

widget.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "APPLICATION_EXTENSION_API_ONLY" => "YES",
    "CODE_SIGN_ENTITLEMENTS" => "Config/LimitsWidgetExtension.entitlements",
    "CURRENT_PROJECT_VERSION" => "1",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "Config/LimitsWidgetExtension-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../../../../Frameworks",
    "MARKETING_VERSION" => "1.0.0",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.WidgetExtension",
    "SKIP_INSTALL" => "YES"
  )
end

unit_tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "BUNDLE_LOADER" => "$(TEST_HOST)",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.Tests",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Limits.app/Contents/MacOS/Limits"
  )
end

ui_tests.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.amir.Limits.UITests",
    "TEST_TARGET_NAME" => "Limits"
  )
end

project.root_object.attributes["TargetAttributes"] = targets.to_h do |target|
  [target.uuid, { "CreatedOnToolsVersion" => "26.0", "DevelopmentTeam" => "M94V58FCVP", "ProvisioningStyle" => "Automatic" }]
end

project.sort
project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, unit_tests, launch_target: app)
scheme.add_test_target(ui_tests)
scheme.save_as(PROJECT_PATH, "Limits", true)

puts PROJECT_PATH
