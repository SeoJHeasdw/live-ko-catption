import Foundation
import CryptoKit

@main struct AdversarialCacheCheck {
 @MainActor static func main() async throws {
  let folder = URL(fileURLWithPath: "/tmp/caption-cache-probe-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = folder.appendingPathComponent("fixture.gguf")
  try Data("abc".utf8).write(to: model)
  let date = Date(timeIntervalSince1970: 100)
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: model.path)
  let stampBefore = try FileManager.default.attributesOfItem(atPath: model.path)
  let manifest = LocalModelManifest(filename: "fixture.gguf", downloadURL: URL(string: "https://invalid.example/model")!, byteCount: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  let store = LocalModelStore(directory: folder, manifest: manifest)
  await store.refresh()
  print("before installed=\(store.isInstalled)")
  let handle = try FileHandle(forWritingTo: model)
  try handle.write(contentsOf: Data("def".utf8))
  try handle.close()
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: model.path)
  let stampAfter = try FileManager.default.attributesOfItem(atPath: model.path)
  await store.refresh()
  print("after installed=\(store.isInstalled), size preserved=\(stampBefore[.size] as? NSNumber == stampAfter[.size] as? NSNumber), inode preserved=\(stampBefore[.systemFileNumber] as? NSNumber == stampAfter[.systemFileNumber] as? NSNumber), actual=\(String(data: try Data(contentsOf: model), encoding: .utf8)!), modelURL exposed=\(store.modelURL != nil)")
 }
}
