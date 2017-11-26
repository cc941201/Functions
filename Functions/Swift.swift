import Foundation

private let template = """
// DO NOT EDIT. Generated by funcgen.
import Foundation

private class EncoderRuntime {
    private var stack = [Function]()

    var level: Int {
        return stack.count - 1
    }

    var current: Function {
        get {
            return stack[level]
        }
        set {
            stack[level] = newValue
        }
    }

    func push() {
        stack.append(Function())
    }

    func pop() -> Function {
        return stack.removeLast()
    }

    static var runtime: EncoderRuntime {
        return Thread.current.threadDictionary.object(forKey: "edu.jhu.Functions.Runtime") as! EncoderRuntime
    }
}

protocol _Producer {
    var producer: Function.A { get }
}

extension Function.A {
    init(argumentNumber: Int) {
        level = UInt32(EncoderRuntime.runtime.level)
        step = Int32(-argumentNumber)
    }

    @discardableResult
    init(producer: Function.Producer.OneOf_Producer) {
        let runtime = EncoderRuntime.runtime
        level = UInt32(runtime.level)
        step = Int32(runtime.current.steps.count)
        var p = Function.Producer()
        p.producer = producer
        runtime.current.steps.append(p)
    }

    var producer: Function.A { return self }
}\n\n
"""

struct Swift: Language {
    static let protobufTypeToNative = [
        "double": "Double", "float": "Float",
        "int32": "Int32", "int64": "Int64",
        "uint32": "UInt32", "uint64": "UInt64",
        "sint32": "Int32", "sint64": "Int64",
        "fixed32": "UInt32", "fixed64": "UInt64",
        "sfixed32": "Int32", "sfixed64": "Int64",
        "bool": "Bool",
        "string": "String", "bytes": "Data"
    ]
    
    func nativeType(for type: String) -> String {
        return Swift.protobufTypeToNative[type] ?? type
    }
    
    let parser: Parser
    
    private func writeCommaSeparated<T: Sequence>(_ sequence: T, to output: inout String, body: (T.Element) -> ()) {
        var first = true
        sequence.forEach {
            if !first { output.append(", ") } else { first = false }
            body($0)
        }
    }
    
    private func writeArgumentsExtension(to output: inout String) {
        for i in parser.argumentNumber.sorted() {
            if i == 0 { continue }
            output.append("extension Function.Producer.A\(i) {\n    init(")
            writeCommaSeparated(1...i, to: &output) {
                output.append("_ o\($0): Function.A")
            }
            output.append(") {\n")
            for j in 1...i {
                output.append("        self.o\(j) = o\(j)\n")
            }
            output.append("    }\n}\n\n")
        }
    }
    
    private func writeFunctionProducer(to output: inout String) {
        output.append("""
            extension Function: _Producer {
                var producer: Function.A {
                    let level = EncoderRuntime.runtime.level + 1
                    if steps.count == 1 && returnStep.step == 0 && returnStep.level == level {
                        switch steps[0].producer {\n
            """)
        for (name, type) in parser.types {
            if case .function(let functionType) = type {
                output.append("            case .\(name)(let a)?:\n")
                if functionType.argumentTypes.count > 0 {
                    output.append("                if ")
                    for i in functionType.argumentTypes.indices {
                        if i != 0 { output.append(" && ") }
                        output.append("a.o\(i + 2).step == -\(i + 1) && a.o\(i + 2).level == level")
                    }
                    output.append(" {\n                    return a.o1\n                }\n")
                } else {
                    output.append("                return a.o1\n")
                }
            }
        }
        output.append("""
                        default: break
                        }
                    }
                    return Function.A(producer: .functionRaw(self))
                }
            }\n\n
            """)
    }
    
    private func writeBasicType(name: String, backed: Bool, to output: inout String) {
        let nativeName = backed ? nativeType(for: name) : name
        output.append("protocol \(nativeName)Producer: ")
        if let types = parser.subtypesMap[name] {
            writeCommaSeparated(types, to: &output) {
                output.append("\(nativeType(for: $0))Producer")
            }
        } else {
            output.append("_Producer")
        }
        output.append(" {}\n\nextension Function.A: \(nativeName)Producer {}\n\n")
        if backed {
            output.append("""
                extension \(nativeName): \(nativeName)Producer {
                    var producer: Function.A {
                        return Function.A(producer: .\(name)Raw(self))
                    }
                }\n\n
                """)
        }
    }
    
    private func writeUnitFunction(name: String, functionType: Parser.FunctionType, to output: inout String) {
        output.append("""
            extension Function.A {
                var \(name)Unit: \(name)Producer {
                    return { Function.A(producer: .\(name)(.init(self
            """)
        for (i, type) in functionType.argumentTypes.enumerated() {
            if case .function? = parser.typesMap[type] {
                output.append(", \(type)EncodeInternal($\(i)).producer")
            } else {
                output.append(", $\(i).producer")
            }
        }
        output.append(")))")
        if let returnType = functionType.returnType, case .function = parser.typesMap[returnType]! {
            output.append(".\(returnType)Unit")
        }
        output.append(" }\n    }\n}\n\n")
    }
    
    private func writeTypealias(name: String, functionType: Parser.FunctionType, to output: inout String) {
        // producer
        output.append("typealias \(name)Producer = (")
        writeCommaSeparated(functionType.argumentTypes, to: &output) {
            if case .function? = parser.typesMap[$0] {
                output.append("@escaping ")
            }
            output.append("\(nativeType(for: $0))Producer")
        }
        if let type = functionType.returnType {
            output.append(") -> \(nativeType(for: type))Producer\n")
        } else {
            output.append(") -> ()\n")
        }
        
        // real
        output.append("typealias \(name) = (")
        writeCommaSeparated(functionType.argumentTypes, to: &output) {
            if case .function? = parser.typesMap[$0] {
                output.append("@escaping ")
            }
            output.append("\(nativeType(for: $0))")
        }
        if let type = functionType.returnType {
            output.append(") -> \(nativeType(for: type))\n\n")
        } else {
            output.append(") -> ()\n\n")
        }
    }
    
    private func writeSymbol(name: String, functionType: Parser.FunctionType, to output: inout String) {
        output.append("func \(name)(")
        writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
            output.append("_ o\($0.offset + 1): \(nativeType(for: $0.element))Producer")
        }
        if let type = functionType.returnType {
            output.append(") -> \(nativeType(for: type))Producer {\n    return ")
        } else {
            output.append(") {\n    ")
        }
        output.append("Function.A(producer: .\(name)(.init(")
        writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
            if case .function? = parser.typesMap[$0.element] {
                output.append("\($0.element)EncodeInternal(o\($0.offset + 1)).producer")
            } else {
                output.append("o\($0.offset + 1).producer")
            }
        }
        output.append(")))")
        if let returnType = functionType.returnType, case .function = parser.typesMap[returnType]! {
            output.append(".\(returnType)Unit")
        }
        output.append("\n}\n\n")
    }
    
    private func writeEncode(name: String, to output: inout String) {
        output.append("""
            func \(name)Encode(_ function: \(name)Producer) -> Function {
                Thread.current.threadDictionary.setObject(EncoderRuntime(), forKey: "edu.jhu.Functions.Runtime" as NSString)
                defer {
                    Thread.current.threadDictionary.removeObject(forKey: "edu.jhu.Functions.Runtime")
                }
                return \(name)EncodeInternal(function)
            }\n\n
            """)
    }
    
    private func writeEncodeInternal(name: String, functionType: Parser.FunctionType, to output: inout String) {
        output.append("""
            private func \(name)EncodeInternal(_ function: \(name)Producer) -> Function {
                let runtime = EncoderRuntime.runtime
                runtime.push()\n
            """)
        if let returnType = functionType.returnType {
            output.append("    let returnStep = function(")
            writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
                output.append("Function.A(argumentNumber: \($0.offset + 1))")
                if case .function? = parser.typesMap[$0.element] {
                    output.append(".\($0.element)Unit")
                }
            }
            if case .function? = parser.typesMap[returnType] {
                output.append(")\n    runtime.current.returnStep = \(returnType)EncodeInternal(returnStep).producer\n")
            } else {
                output.append(")\n    runtime.current.returnStep = returnStep.producer\n")
            }
        } else {
            output.append("    function(")
            writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
                output.append("Function.A(argumentNumber: \($0.offset + 1))")
                if case .function? = parser.typesMap[$0.element] {
                    output.append(".\($0.element)Unit")
                }
            }
            output.append(")\n")
        }
        
        output.append("    return runtime.pop()\n}\n\n")
    }
    
    private func writeDecode(name: String, functionType: Parser.FunctionType, to output: inout String) {
        output.append("""
            func \(name)Decode(function: Function, symbols: Symbols) throws -> \(name) {
                let decoderRuntime = DecoderRuntime()
                try decoderRuntime.typecheck(function: function, arguments: [
            """)
        writeCommaSeparated(functionType.argumentTypes, to: &output) {
            output.append(".\($0)Type")
        }
        if let type = functionType.returnType {
            output.append("], returnType: .\(type)Type)\n    return {")
        } else {
            output.append("], returnType: .none)\n    return {")
        }
        if let type = functionType.returnType, case .function? = parser.typesMap[type] {
            output.append("\n        let result = decoderRuntime.run(function: function, symbols: symbols, arguments: [")
            writeCommaSeparated(functionType.argumentTypes.indices, to: &output) {
                output.append("$\($0)")
            }
            output.append("""
                ])
                        if let function = result as? ([Any]) -> Any? {
                            return \(type)Run(function)
                        } else {
                            return result as! \(type)
                        }
                    }
                }\n\n
                """)
        } else {
            output.append(" decoderRuntime.run(function: function, symbols: symbols, arguments: [")
            writeCommaSeparated(functionType.argumentTypes.indices, to: &output) {
                output.append("$\($0)")
            }
            if let type = functionType.returnType {
                output.append("]) as! \(nativeType(for: type)) }\n}\n\n")
            } else {
                output.append("]) }\n}\n\n")
            }
        }
    }
    
    private func writeRun(name: String, functionType: Parser.FunctionType, to output: inout String) {
        output.append("private func \(name)Run(_ function: @escaping ([Any]) -> Any?) -> \(name) {\n    return { ")
        if functionType.returnType == nil {
            output.append("_ = ")
        }
        output.append("function([")
        writeCommaSeparated(functionType.argumentTypes.indices, to: &output) {
            output.append("$\($0)")
        }
        if let type = functionType.returnType {
            output.append("]) as! \(nativeType(for: type)) }\n}\n\n")
        } else {
            output.append("]) }\n}\n\n")
        }
    }
    
    private func writeSymbolsProtocol(to output: inout String) {
        output.append("protocol Symbols {\n")
        for (name, functionType) in parser.symbols {
            output.append("    func \(name)(")
            writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
                output.append("_ o\($0.offset + 1): ")
                if case .function? = parser.typesMap[$0.element] {
                    output.append("@escaping ")
                }
                output.append("\(nativeType(for: $0.element))")
            }
            if let type = functionType.returnType {
                output.append(") -> \(nativeType(for: type))\n")
            } else {
                output.append(") -> ()\n")
            }
        }
        output.append("}\n\n")
    }
    
    private func writeDecoder(to output: inout String) {
        output.append("""
            struct DecodeError: Error {
                enum Cause {
                    case argumentMismatch, stepMismatch, returnMismatch, argumentMissing, stepMissing, returnMissing, invalidFormat
                }
                var cause: Cause
                var stack: IndexPath
            }

            private class DecoderRuntime {
                private class Runtime<T> {
                    var results = [Int: T]()
                    let arguments: [T]
                    init(arguments: [T]) {
                        self.arguments = arguments
                    }
                }

                private class TypecheckRuntime: Runtime<DeclarationType> {
                    let function: Function
                    let returnType: DeclarationType
                    var releaseResult: [Int]
                    init(function: Function, arguments: [DeclarationType], returnType: DeclarationType) {
                        self.function = function
                        self.returnType = returnType
                        releaseResult = Array(0..<function.steps.count)
                        super.init(arguments: arguments)
                    }
                }

                private var releaseResults = [IndexPath: [Int: [Int]]]()

                private static func codePath(for a: Function.A, in codePath: IndexPath) -> IndexPath {
                    return codePath[0..<Int(a.level)].appending(Int(a.step))
                }

                enum DeclarationType {
                    case none\n
            """)
        for (name, _) in parser.types {
            output.append("        case \(name)Type\n")
        }
        if parser.subtypesMap.isEmpty {
            output.append("    }\n\n    private let supertypes: [DeclarationType: [DeclarationType]] = [:")
        } else {
            output.append("    }\n\n    private let supertypes: [DeclarationType: [DeclarationType]] = [\n")
            for (subtype, types) in parser.subtypesMap {
                output.append("        .\(subtype)Type: [")
                writeCommaSeparated(types, to: &output) {
                    output.append(".\($0)Type")
                }
                output.append("],\n")
            }
        }
        output.append("""
                ]

                private func isSubtype(_ subtype: DeclarationType, _ type: DeclarationType) -> Bool {
                    if subtype == type { return true }
                    for supertype in supertypes[subtype, default: []] {
                        if isSubtype(supertype, type) { return true }
                    }
                    return false
                }

                private func check(_ a: Function.A, with type: DeclarationType, stack: [TypecheckRuntime], codePath: IndexPath, callStack: IndexPath) throws {
                    if a.step >= 0 {
                        guard a.level < stack.count else { throw DecodeError(cause: .stepMissing, stack: callStack) }
                        let runtime = stack[Int(a.level)]
                        if let t = runtime.results[Int(a.step)] {
                            if !isSubtype(t, type) { throw DecodeError(cause: .stepMismatch, stack: callStack) }
                            runtime.releaseResult[Int(a.step)] = callStack[Int(a.level)]
                        } else {
                            guard a.step < runtime.function.steps.count, case .functionRaw(let f)? = runtime.function.steps[Int(a.step)].producer else { throw DecodeError(cause: .stepMissing, stack: callStack) }
                            let codePath = DecoderRuntime.codePath(for: a, in: codePath)
                            runtime.results[Int(a.step)] = type
                            switch type {\n
            """)
        for (name, type) in parser.types {
            if case .function(let functionType) = type {
                output.append("                case .\(name)Type:\n                    let nextRuntime = TypecheckRuntime(function: f, arguments: [")
                writeCommaSeparated(functionType.argumentTypes, to: &output) {
                    output.append(".\($0)Type")
                }
                if let type = functionType.returnType {
                    output.append("], returnType: .\(type)Type")
                } else {
                    output.append("], returnType: .none")
                }
                output.append(")\n                    try typecheck(stack: stack + [nextRuntime], codePath: codePath, callStack: callStack)\n")
            }
        }
        output.append("""
                            default:
                                throw DecodeError(cause: .stepMismatch, stack: callStack)
                            }
                            runtime.results[Int(a.step)] = nil
                            runtime.releaseResult[Int(a.step)] = callStack[Int(a.level)]
                        }
                    } else {
                        guard a.level < stack.count else { throw DecodeError(cause: .argumentMissing, stack: callStack) }
                        let runtime = stack[Int(a.level)]
                        let number = Int(-a.step - 1)
                        guard number < runtime.arguments.count else { throw DecodeError(cause: .argumentMissing, stack: callStack) }
                        if !isSubtype(runtime.arguments[number], type) { throw DecodeError(cause: .argumentMismatch, stack: callStack) }
                    }
                }
                
                private func typecheck(stack: [TypecheckRuntime], codePath: IndexPath, callStack: IndexPath) throws {
                    let runtime = stack.last!
                    for (i, step) in runtime.function.steps.enumerated() {
                        let callStack = callStack.appending(i)
                        guard let producer = step.producer else { throw DecodeError(cause: .invalidFormat, stack: callStack) }
                        switch producer {
                        case .functionRaw: break\n
            """)
        for (name, type) in parser.types {
            switch type {
            case .basic(backed: true):
                output.append("""
                                case .\(name)Raw:
                                    runtime.results[i] = .\(name)Type\n
                    """)
            case .basic(backed: false): break
            case .function(let functionType):
                output.append("            case .\(name)(let a):\n")
                for (i, type) in ([name] + functionType.argumentTypes).enumerated() {
                    output.append("                try check(a.o\(i + 1), with: .\(type)Type, stack: stack, codePath: codePath, callStack: callStack)\n")
                }
                if let type = functionType.returnType {
                    output.append("                runtime.results[i] = .\(type)Type\n")
                } else {
                    output.append("                runtime.results[i] = .none\n")
                }
            }
        }
        
        for (name, functionType) in parser.symbols {
            if functionType.argumentTypes.count > 0 {
                output.append("            case .\(name)(let a):\n")
                for (i, type) in functionType.argumentTypes.enumerated() {
                    output.append("                try check(a.o\(i + 1), with: .\(type)Type, stack: stack, codePath: codePath, callStack: callStack)\n")
                }
            } else {
                output.append("            case .\(name):\n")
            }
            if let type = functionType.returnType {
                output.append("                runtime.results[i] = .\(type)Type\n")
            } else {
                output.append("                runtime.results[i] = .none\n")
            }
        }
        output.append("""
                        }
                    }
                    if runtime.returnType != .none {
                        let callStack = callStack.appending(runtime.function.steps.count)
                        guard runtime.function.hasReturnStep else { throw DecodeError(cause: .returnMissing, stack: callStack) }
                        try check(runtime.function.returnStep, with: runtime.returnType, stack: stack, codePath: codePath, callStack: callStack)
                    } else if runtime.function.hasReturnStep { throw DecodeError(cause: .returnMismatch, stack: callStack) }
                    releaseResults[codePath] = Dictionary(grouping: runtime.releaseResult.enumerated()) { $0.element }.mapValues { $0.map { $0.offset } }
                }
                
                func typecheck(function: Function, arguments: [DeclarationType], returnType: DeclarationType) throws {
                    try typecheck(stack: [TypecheckRuntime(function: function, arguments: arguments, returnType: returnType)], codePath: [], callStack: [])
                }

                private func value(_ a: Function.A, in stack: [Runtime<Any>]) -> Any {
                    if a.step >= 0 {
                        return stack[Int(a.level)].results[Int(a.step)]!
                    } else {
                        return stack[Int(a.level)].arguments[Int(-a.step - 1)]
                    }
                }\n\n
            """)
        for (name, type) in parser.types {
            if case .function(let functionType) = type {
                output.append("""
                        private func \(name)Value(_ a: Function.A, in stack: [Runtime<Any>], symbols: Symbols, codePath: IndexPath) -> \(name) {
                            let raw = value(a, in: stack)
                            if let function = raw as? Function {
                                let codePath = DecoderRuntime.codePath(for: a, in: codePath)
                                return { self.run(function: function, symbols: symbols, stack: stack + [Runtime(arguments: [
                    """)
                writeCommaSeparated(functionType.argumentTypes.indices, to: &output) {
                    output.append("$\($0)")
                }
                if let type = functionType.returnType {
                    output.append("])], codePath: codePath) as! \(nativeType(for: type)) }\n")
                } else {
                    output.append("])], codePath: codePath) }\n")
                }
                output.append("""
                            } else {
                                return raw as! \(name)
                            }
                        }\n\n
                    """)
            }
        }
        output.append("""
                @discardableResult
                private func run(function: Function, symbols: Symbols, stack: [Runtime<Any>], codePath: IndexPath) -> Any? {
                    let runtime = stack.last!
                    let releaseResult = releaseResults[codePath]!
                    for (i, step) in function.steps.enumerated() {
                        switch step.producer! {
                        case .functionRaw(let raw):
                            runtime.results[i] = raw\n
            """)
        for (name, type) in parser.types {
            switch type {
            case .basic(backed: true):
                output.append("""
                                case .\(name)Raw(let raw):
                                    runtime.results[i] = raw\n
                    """)
            case .basic(backed: false): break
            case .function(let functionType):
                output.append("            case .\(name)(let a):\n                ")
                if functionType.returnType != nil {
                    output.append("runtime.results[i] = \(name)Value(a.o1, in: stack, symbols: symbols, codePath: codePath)(")
                } else {
                    output.append("\(name)Value(a.o1, in: stack, symbols: symbols, codePath: codePath)(")
                }
                writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
                    if case .function? = parser.typesMap[$0.element] {
                        output.append("\($0.element)Value(a.o\($0.offset + 2), in: stack, symbols: symbols, codePath: codePath)")
                    } else {
                        output.append("value(a.o\($0.offset + 2), in: stack) as! \(nativeType(for: $0.element))")
                    }
                }
                output.append(")\n")
            }
        }
        
        for (name, functionType) in parser.symbols {
            if functionType.argumentTypes.count > 0 {
                output.append("            case .\(name)(let a):\n                ")
            } else {
                output.append("            case .\(name):\n                ")
            }
            if functionType.returnType != nil {
                output.append("runtime.results[i] = symbols.\(name)(")
            } else {
                output.append("symbols.\(name)(")
            }
            writeCommaSeparated(functionType.argumentTypes.enumerated(), to: &output) {
                if case .function? = parser.typesMap[$0.element] {
                    output.append("\($0.element)Value(a.o\($0.offset + 1), in: stack, symbols: symbols, codePath: codePath)")
                } else {
                    output.append("value(a.o\($0.offset + 1), in: stack) as! \(nativeType(for: $0.element))")
                }
            }
            output.append(")\n")
        }
        output.append("""
                        }
                        releaseResult[i]?.forEach { runtime.results[$0] = nil }
                    }
                    if !function.hasReturnStep { return nil }
                    let returnValue = value(function.returnStep, in: stack)
                    if let returnFunction = returnValue as? Function {
                        return { self.run(function: returnFunction, symbols: symbols, stack: stack + [Runtime(arguments: $0)], codePath: DecoderRuntime.codePath(for: function.returnStep, in: codePath)) }
                    } else {
                        return returnValue
                    }
                }

                @discardableResult
                func run(function: Function, symbols: Symbols, arguments: [Any]) -> Any? {
                    return run(function: function, symbols: symbols, stack: [Runtime(arguments: arguments)], codePath: [])
                }
            }\n\n
            """)
    }
    
    private func writeTextualRepresentation(to output: inout String) {
        output.append("""
            extension Function.A: CustomStringConvertible {
                var description: String {
                    if step < 0 {
                        return "$\\(level):\\(-step - 1)"
                    } else {
                        return "%\\(level):\\(step)"
                    }
                }
            }

            extension Function: CustomStringConvertible {
                private func textualRepresentation(level: Int) -> String {
                    let ident = (0..<level).reduce("") { ident, _ in ident + "    " }
                    var rep = ""
                    for (i, step) in steps.enumerated() {
                        guard let producer = step.producer else { continue }
                        rep.append(ident)
                        switch producer {
                        case .functionRaw(let f):
                            rep.append("%\\(level):\\(i) = {\\n\\(f.textualRepresentation(level: level + 1))\\(ident)}\\n")\n
            """)
        for (name, type) in parser.types {
            switch type {
            case .basic(backed: true):
                output.append("""
                                case .\(name)Raw(let raw):
                                    rep.append("%\\(level):\\(i) = (\(name))\\(raw)\\n")\n
                    """)
            case .basic(backed: false): break
            case .function(let functionType):
                output.append("            case .\(name)(let a):\n                rep.append(\"")
                if functionType.returnType != nil {
                    output.append("%\\(level):\\(i) = ")
                }
                output.append("(\(name))\\(a.o1)(")
                writeCommaSeparated(0..<functionType.argumentTypes.count, to: &output) {
                    output.append("\\(a.o\($0 + 2))")
                }
                output.append(")\\n\")\n")
            }
        }
        
        for (name, functionType) in parser.symbols {
            if functionType.argumentTypes.count > 0 {
                output.append("            case .\(name)(let a):\n                rep.append(\"")
            } else {
                output.append("            case .\(name):\n                rep.append(\"")
            }
            if functionType.returnType != nil {
                output.append("%\\(level):\\(i) = ")
            }
            output.append("\(name)(")
            writeCommaSeparated(functionType.argumentTypes.indices, to: &output) {
                output.append("\\(a.o\($0 + 1))")
            }
            output.append(")\\n\")\n")
        }
        output.append("""
                        }
                    }
                    if hasReturnStep {
                        rep.append("\\(ident)return \\(returnStep)\\n")
                    }
                    return rep
                }
            
                var description: String {
                    return textualRepresentation(level: 0)
                }
            }
            """)
    }
    
    func generate(_ url: URL) {
        var output = template
        
        writeArgumentsExtension(to: &output)
        
        writeFunctionProducer(to: &output)
        
        for (name, type) in parser.types {
            switch type {
            case .basic(let backed):
                writeBasicType(name: name, backed: backed, to: &output)
            case .function(let functionType):
                writeTypealias(name: name, functionType: functionType, to: &output)
                writeUnitFunction(name: name, functionType: functionType, to: &output)
                writeEncodeInternal(name: name, functionType: functionType, to: &output)
                writeDecode(name: name, functionType: functionType, to: &output)
                writeRun(name: name, functionType: functionType, to: &output)
            }
        }
        
        for (name, functionType) in parser.symbols {
            writeSymbol(name: name, functionType: functionType, to: &output)
        }
        
        for (name, functionType) in parser.functions {
            writeTypealias(name: name, functionType: functionType, to: &output)
            writeEncode(name: name, to: &output)
            writeEncodeInternal(name: name, functionType: functionType, to: &output)
            writeDecode(name: name, functionType: functionType, to: &output)
        }
        
        writeSymbolsProtocol(to: &output)
        
        writeDecoder(to: &output)
        
        writeTextualRepresentation(to: &output)
        
        try! output.write(to: url, atomically: true, encoding: .utf8)
    }
}
