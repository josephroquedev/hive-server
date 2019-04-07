//
//  HiveMindProcess.swift
//  App
//
//  Created by Joseph Roque on 2019-03-17.
//

import Foundation
import HiveEngine
import Vapor

class HiveMindProcess {

	private static let explorationTime: TimeInterval = 10

	/// Location of the HiveMind executable
	/// FIXME: Replace with something more generic
	private var executable: URL {
		return FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Documents")
			.appendingPathComponent("Workspace")
			.appendingPathComponent("hivemind")
			.appendingPathComponent(".build")
			.appendingPathComponent("debug")
			.appendingPathComponent("HiveMind")
	}

	private let process = Process()

	private let processInput = Pipe()
	private let processOutput = Pipe()

	init(isFirst: Bool) throws {
		process.executableURL = executable
		process.standardInput = processInput
		process.standardOutput = processOutput
		try process.run()

		// Allow time for the HiveMind to initialize its process then write data
		DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
			do {
				let newProcessCommand = "new \(isFirst) \(HiveMindProcess.explorationTime)\n"
				try self.writeCommand(newProcessCommand)
				self.processPrint("Initialized HiveMindProcess")
				print("(PID \(self.process.processIdentifier)): Initialized HiveMindProcess")
			} catch {
				self.processPrint("Failed to initialize HiveMindProcess: \(error.localizedDescription)")
			}
		}
	}

	deinit {
		close()
	}

	/// Ask for a `Movement` from the HiveMind.
	///
	/// - Parameters:
	///   - req: the server request made
	func play(req: Request) -> Future<Movement> {
		processPrint("Playing move")
		let movementPromise = req.eventLoop.newPromise(of: Movement.self)

		// Write the command to the process
		do {
			// Clear output from process before sending input
			_ = processOutput.fileHandleForReading.availableData
			try writeCommand("play\n")
		} catch {
			movementPromise.fail(error: error)
			return movementPromise.futureResult
		}

		let explorationTime = HiveMindProcess.explorationTime + 2
		DispatchQueue.global().asyncAfter(deadline: .now() + explorationTime) { [weak self] in
			guard let self = self else { return }

			let hiveMindOutput = self.processOutput.fileHandleForReading.availableData
			let (movement, error) = self.movement(from: hiveMindOutput)
			guard error == nil else {
				movementPromise.fail(error: error!)
				return
			}

			movementPromise.succeed(result: movement!)
		}

		return movementPromise.futureResult
	}

	/// Forward a `Movement` to the HiveMind.
	///
	/// - Parameters:
	///   - move: the movement to apply, which should be valid in the HiveMind's current state.
	///           If the movement is not valid, the HiveMind process will fail silently.
	func apply(move: Movement) {
		processPrint("Applying movement `\(move)")

		let encoder = JSONEncoder()
		guard let data = try? encoder.encode(move), let moveString = String(data: data, encoding: .utf8) else {
			print("Failed to convert \(move) to JSON")
			return
		}

		do {
			try writeCommand("move \(moveString)\n")
		} catch {
			print(error)
		}
	}

	/// Close the current HiveMind process.
	func close() {
		if process.isRunning {
			process.terminate()
			print("(PID \(process.processIdentifier)): Terminated HiveMindProcess")
		}
	}

	/// Get a `Movement` from JSON encoded data. Returns the movement, or nil and an error
	/// if there were any errors.
	private func movement(from data: Data) -> (Movement?, Error?) {
		guard let dataAsString = String(data: data, encoding: .utf8) else {
			return (nil, HiveMindError.dataToStringConversion)
		}

		guard let cleanData = extractJSONData(from: dataAsString) else {
			return (nil, HiveMindError.JSONExtraction(dataAsString))
		}

		let decoder = JSONDecoder()
		do {
			let move = try decoder.decode(Movement.self, from: cleanData)
			return (move, nil)
		} catch {
			return (nil, error)
		}
	}

	/// Given a `String`, extracts the first JSON object to appear in the `String`
	/// and returns it as `Data`
	private func extractJSONData(from string: String) -> Data? {
		guard let startIndex = string.firstIndex(of: "{") else { return nil }
		var endIndex = string.index(after: startIndex)
		var depth = 1
		while depth > 0 && endIndex != string.endIndex {
			switch string[endIndex] {
			case "{": depth += 1
			case "}": depth -= 1
			default:
				// Does nothing
				break
			}
			endIndex = string.index(after: endIndex)
		}

		return string[startIndex..<endIndex].data(using: .utf8)
	}

	/// Print a String with the current process's identifier.
	private func processPrint(_ string: String) {
		print("(PID \(self.process.processIdentifier)):", string)
	}

	/// Attempt to write a command to the current Process and throw any errors.
	private func writeCommand(_ command: String) throws {
		guard let writeData = command.data(using: .utf8) else {
			throw HiveMindError.stringToDataConversion(command)
		}

		processInput.fileHandleForWriting.write(writeData)
	}
}