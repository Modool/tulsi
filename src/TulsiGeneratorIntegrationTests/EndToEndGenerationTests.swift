// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import TulsiGenerator


// End to end tests that generate xcodeproj bundles and validate them against golden versions.
class EndToEndGenerationTests: BazelIntegrationTestCase {
  let fakeBazelURL = NSURL(fileURLWithPath: "/fake/tulsi_test_bazel", isDirectory: false)

  func testGeneration_SimpleProject() {
    let testDir = "tulsi_e2e_simple"
    installBUILDFile("Simple", intoSubdirectory: testDir)
    makeTestXCDataModel("SimpleDataModelsTestv1", inSubdirectory: "\(testDir)/SimpleTest.xcdatamodeld")
    makeTestXCDataModel("SimpleDataModelsTestv2", inSubdirectory: "\(testDir)/SimpleTest.xcdatamodeld")
    makePlistFileNamed(".xccurrentversion",
                       withContent: ["_XCCurrentVersionName": "SimpleDataModelsTestv1.xcdatamodel"],
                       inSubdirectory: "\(testDir)/SimpleTest.xcdatamodeld")

    let buildTargets = [RuleInfo(label: BuildLabel("//\(testDir):Application"), type: "ios_application"),
                        RuleInfo(label: BuildLabel("//\(testDir):XCTest"), type: "ios_test")]
    let additionalFilePaths = ["\(testDir)/BUILD"]

    guard let projectURL = generateProjectNamed("SimpleProject",
                                                buildTargets: buildTargets,
                                                pathFilters: ["\(testDir)/..."],
                                                additionalFilePaths: additionalFilePaths,
                                                outputDir: "tulsi_e2e_output/") else {
      return
    }

    let diffLines = diffProjectAt(projectURL, againstGoldenProject: "SimpleProject")
    validateDiff(diffLines)
  }

  func testGeneration_ComplexSingleProject() {
    let testDir = "tulsi_e2e_complex"
    installBUILDFile("ComplexSingle", intoSubdirectory: testDir)
    makeTestXCDataModel("DataModelsTestv1", inSubdirectory: "\(testDir)/Test.xcdatamodeld")
    makeTestXCDataModel("DataModelsTestv2", inSubdirectory: "\(testDir)/Test.xcdatamodeld")

    let buildTargets = [RuleInfo(label: BuildLabel("//\(testDir):Application"), type: "ios_application"),
                        RuleInfo(label: BuildLabel("//\(testDir):XCTest"), type: "ios_test")]
    let additionalFilePaths = ["\(testDir)/BUILD"]

    guard let projectURL = generateProjectNamed("ComplexSingleProject",
                                                buildTargets: buildTargets,
                                                pathFilters: ["\(testDir)/..."],
                                                additionalFilePaths: additionalFilePaths,
                                                outputDir: "tulsi_e2e_output/") else {
      return
    }

    let diffLines = diffProjectAt(projectURL, againstGoldenProject: "ComplexSingleProject")
    validateDiff(diffLines)
  }

  func testGeneration_TestSuiteExplicitXCTestsProject() {
    let testDir = "TestSuite"
    installBUILDFile("TestSuiteRoot",
                     intoSubdirectory: testDir,
                     fromResourceDirectory: "TestSuite")
    installBUILDFile("TestOne",
                     intoSubdirectory: "\(testDir)/One",
                     fromResourceDirectory: "TestSuite/One")
    installBUILDFile("TestTwo",
                     intoSubdirectory: "\(testDir)/Two",
                     fromResourceDirectory: "TestSuite/Two")
    installBUILDFile("TestThree",
                     intoSubdirectory: "\(testDir)/Three",
                     fromResourceDirectory: "TestSuite/Three")

    // TODO(abaire): Add the test suite target(s).
    let buildTargets = [RuleInfo(label: BuildLabel("//\(testDir):TestApplication"), type: "ios_application")]

    guard let projectURL = generateProjectNamed("TestSuiteExplicitXCTestsProject",
                                                buildTargets: buildTargets,
                                                pathFilters: ["\(testDir)/..."],
                                                outputDir: "tulsi_e2e_output/") else {
      return
    }

    let diffLines = diffProjectAt(projectURL, againstGoldenProject: "TestSuiteExplicitXCTestsProject")
    validateDiff(diffLines)
  }

  // MARK: Private methods

  private func validateDiff(diffLines: [String], line: UInt = #line) {
    for diff in diffLines {
      // .tulsigen-user files are omitted from the golden output and can be ignored.
      if diff.hasSuffix(".tulsigen-user") || diff.hasSuffix("bazel_env.sh") {
        continue
      }
      XCTFail(diff, line: line)
    }
  }

  private func diffProjectAt(projectURL: NSURL,
                             againstGoldenProject resourceName: String,
                             line: UInt = #line) -> [String] {
    let bundle = NSBundle(forClass: self.dynamicType)
    guard let goldenProjectURL = bundle.URLForResource(resourceName,
                                                       withExtension: "xcodeproj",
                                                       subdirectory: "GoldenProjects") else {
      assertionFailure("Missing required test resource file \(resourceName).xcodeproj")
      XCTFail("Missing required test resource file \(resourceName).xcodeproj", line: line)
      return []
    }

    var diffOutput = [String]()
    let semaphore = dispatch_semaphore_create(0)
    let task = TaskRunner.standardRunner().createTask("/usr/bin/diff",
                                                      arguments: ["-rq",
                                                                  projectURL.path!,
                                                                  goldenProjectURL.path!]) {
      completionInfo in
        defer {
          dispatch_semaphore_signal(semaphore)
        }
        if let stdout = NSString(data: completionInfo.stdout, encoding: NSUTF8StringEncoding) {
          diffOutput = stdout.componentsSeparatedByString("\n").filter({ !$0.isEmpty })
        } else {
          XCTFail("No output received for diff command", line: line)
        }
    }
    task.currentDirectoryPath = workspaceRootURL.path!
    task.launch()

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
    return diffOutput
  }

  private func generateProjectNamed(projectName: String,
                                    buildTargets: [RuleInfo],
                                    pathFilters: [String],
                                    additionalFilePaths: [String] = [],
                                    outputDir: String) -> NSURL? {
    let options = TulsiOptionSet()
    let userDefaults = NSUserDefaults.standardUserDefaults()
    if let startupOptions = userDefaults.stringForKey("testBazelStartupOptions") {
      options[.BazelBuildStartupOptionsDebug].projectValue = startupOptions
    }
    if let buildOptions = userDefaults.stringForKey("testBazelBuildOptions") {
      options[.BazelBuildOptionsDebug].projectValue = buildOptions
    }

    let config = TulsiGeneratorConfig(projectName: projectName,
                                      buildTargets: buildTargets,
                                      pathFilters: Set<String>(pathFilters),
                                      additionalFilePaths: additionalFilePaths,
                                      options: options,
                                      bazelURL: fakeBazelURL)

    guard let outputFolderURL = makeTestSubdirectory(outputDir) else {
      XCTFail("Failed to create output folder, aborting test.")
      return nil
    }

    let extractor = BazelWorkspaceInfoExtractor(bazelURL: bazelURL,
                                                workspaceRootURL: workspaceRootURL,
                                                localizedMessageLogger: localizedMessageLogger)
    let projectGenerator = TulsiXcodeProjectGenerator(workspaceRootURL: workspaceRootURL,
                                                      config: config,
                                                      messageLogger: localizedMessageLogger.messageLogger,
                                                      workspaceInfoExtractor: extractor)
    let errorInfo: String
    do {
      return try projectGenerator.generateXcodeProjectInFolder(outputFolderURL)
    } catch TulsiXcodeProjectGenerator.Error.UnsupportedTargetType(let targetType) {
      errorInfo = "Unsupported target type: \(targetType)"
    } catch TulsiXcodeProjectGenerator.Error.SerializationFailed(let details) {
      errorInfo = "General failure: \(details)"
    } catch _ {
      errorInfo = "Unexpected failure"
    }
    XCTFail(errorInfo)
    return nil
  }
}