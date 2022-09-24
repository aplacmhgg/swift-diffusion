import C_ccv
import Diffusion
import Foundation
import NNC

public struct DiffusionModel {
  public var linearStart: Float
  public var linearEnd: Float
  public var timesteps: Int
  public var steps: Int
}

extension DiffusionModel {
  public var betas: [Float] {  // Linear for now.
    var betas = [Float]()
    let start = linearStart.squareRoot()
    let length = linearEnd.squareRoot() - start
    for i in 0..<timesteps {
      let beta = start + Float(i) * length / Float(timesteps - 1)
      betas.append(beta * beta)
    }
    return betas
  }
  public var alphasCumprod: [Float] {
    var cumprod: Float = 1
    return betas.map {
      cumprod *= 1 - $0
      return cumprod
    }
  }
}

DynamicGraph.setSeed(40)

let unconditionalGuidanceScale: Float = 7.5
let scaleFactor: Float = 0.18215
let startWidth: Int = 64
let startHeight: Int = 64
let model = DiffusionModel(linearStart: 0.00085, linearEnd: 0.012, timesteps: 1_000, steps: 50)
let tokenizer = CLIPTokenizer(
  vocabulary: "examples/clip/vocab.json", merges: "examples/clip/merges.txt")

let workDir = CommandLine.arguments[1]
let text = CommandLine.arguments.suffix(2).joined(separator: " ")

let unconditionalTokens = tokenizer.tokenize(text: "", truncation: true, maxLength: 77)
let tokens = tokenizer.tokenize(text: text, truncation: true, maxLength: 77)

let graph = DynamicGraph()

let textModel = CLIPTextModel(
  vocabularySize: 49408, maxLength: 77, embeddingSize: 768, numLayers: 12, numHeads: 12,
  batchSize: 2, intermediateSize: 3072)

let tokensTensor = graph.variable(.CPU, .C(2 * 77), of: Int32.self)
let positionTensor = graph.variable(.CPU, .C(2 * 77), of: Int32.self)
for i in 0..<77 {
  tokensTensor[i] = unconditionalTokens[i]
  tokensTensor[i + 77] = tokens[i]
  positionTensor[i] = Int32(i)
  positionTensor[i + 77] = Int32(i)
}

let casualAttentionMask = graph.variable(Tensor<Float>(.CPU, .NHWC(1, 1, 77, 77)))
casualAttentionMask.full(0)
for i in 0..<76 {
  for j in (i + 1)..<77 {
    casualAttentionMask[0, 0, i, j] = -Float.greatestFiniteMagnitude
  }
}

var ts = [Tensor<Float>]()
for i in 0..<model.steps {
  let timestep = model.timesteps - model.timesteps / model.steps * (i + 1) + 1
  ts.append(
    timeEmbedding(timestep: timestep, batchSize: 2, embeddingSize: 320, maxPeriod: 10_000).toGPU(0))
}
let unet = UNet(batchSize: 2, startWidth: startWidth, startHeight: startHeight)
let decoder = Decoder(
  channels: [128, 256, 512, 512], numRepeat: 2, batchSize: 1, startWidth: startWidth,
  startHeight: startHeight)

func xPrevAndPredX0(
  x: DynamicGraph.Tensor<Float>, et: DynamicGraph.Tensor<Float>, alpha: Float, alphaPrev: Float
) -> (DynamicGraph.Tensor<Float>, DynamicGraph.Tensor<Float>) {
  let predX0 = (1 / alpha.squareRoot()) * (x - (1 - alpha).squareRoot() * et)
  let dirXt = (1 - alphaPrev).squareRoot() * et
  let xPrev = alphaPrev.squareRoot() * predX0 + dirXt
  return (xPrev, predX0)
}

graph.workspaceSize = 1_024 * 1_024 * 1_024

graph.withNoGrad {
  let tokensTensorGPU = tokensTensor.toGPU(0)
  let positionTensorGPU = positionTensor.toGPU(0)
  let casualAttentionMaskGPU = casualAttentionMask.toGPU(0)
  let _ = textModel(inputs: tokensTensorGPU, positionTensorGPU, casualAttentionMaskGPU)
  graph.openStore(workDir + "/sd-v1.4.ckpt") {
    $0.read("text_model", model: textModel)
  }
  let c = textModel(inputs: tokensTensorGPU, positionTensorGPU, casualAttentionMaskGPU)[0].as(
    of: Float.self
  ).reshaped(.CHW(2, 77, 768))
  let x_T = graph.variable(.GPU(0), .NCHW(1, 4, startHeight, startWidth), of: Float.self)
  x_T.randn(std: 1, mean: 0)
  var x = x_T
  var xIn = graph.variable(.GPU(0), .NCHW(2, 4, startHeight, startWidth), of: Float.self)
  let _ = unet(inputs: xIn, graph.variable(ts[0]), c)
  let _ = decoder(inputs: x)
  graph.openStore(workDir + "/sd-v1.4.ckpt") {
    $0.read("unet", model: unet)
    $0.read("decoder", model: decoder)
  }
  let alphasCumprod = model.alphasCumprod
  var oldEps = [DynamicGraph.Tensor<Float>]()
  let startTime = Date()
  DynamicGraph.setProfiler(true)
  // Now do PLMS sampling.
  for i in 0..<model.steps {
    let timestep = model.timesteps - model.timesteps / model.steps * (i + 1) + 1
    let t = graph.variable(ts[i])
    let tNext = ts[min(i + 1, ts.count - 1)]
    xIn[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] = x
    xIn[1..<2, 0..<4, 0..<startHeight, 0..<startWidth] = x
    var et = unet(inputs: xIn, t, c)[0].as(of: Float.self)
    var etUncond = graph.variable(.GPU(0), .NCHW(1, 4, startHeight, startWidth), of: Float.self)
    var etCond = graph.variable(.GPU(0), .NCHW(1, 4, startHeight, startWidth), of: Float.self)
    etUncond[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] =
      et[0..<1, 0..<4, 0..<startHeight, 0..<startWidth]
    etCond[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] =
      et[1..<2, 0..<4, 0..<startHeight, 0..<startWidth]
    et = etUncond + unconditionalGuidanceScale * (etCond - etUncond)
    let alpha = alphasCumprod[timestep]
    let alphaPrev = alphasCumprod[max(timestep - model.timesteps / model.steps, 0)]
    let etPrime: DynamicGraph.Tensor<Float>
    switch oldEps.count {
    case 0:
      let (xPrev, _) = xPrevAndPredX0(x: x, et: et, alpha: alpha, alphaPrev: alphaPrev)
      // Compute etNext.
      xIn[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] = xPrev
      xIn[1..<2, 0..<4, 0..<startHeight, 0..<startWidth] = xPrev
      var etNext = unet(inputs: xIn, graph.variable(tNext), c)[0].as(of: Float.self)
      var etNextUncond = graph.variable(
        .GPU(0), .NCHW(1, 4, startHeight, startWidth), of: Float.self)
      var etNextCond = graph.variable(.GPU(0), .NCHW(1, 4, startHeight, startWidth), of: Float.self)
      etNextUncond[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] =
        etNext[0..<1, 0..<4, 0..<startHeight, 0..<startWidth]
      etNextCond[0..<1, 0..<4, 0..<startHeight, 0..<startWidth] =
        etNext[1..<2, 0..<4, 0..<startHeight, 0..<startWidth]
      etNext = etNextUncond + unconditionalGuidanceScale * (etNextCond - etNextUncond)
      etPrime = 0.5 * (et + etNext)
    case 1:
      etPrime = 0.5 * (3 * et - oldEps[0])
    case 2:
      etPrime =
        Float(1) / Float(12) * (Float(23) * et - Float(16) * oldEps[1] + Float(5) * oldEps[0])
    case 3:
      etPrime =
        Float(1) / Float(24)
        * (Float(55) * et - Float(59) * oldEps[2] + Float(37) * oldEps[1] - Float(9) * oldEps[0])
    default:
      fatalError()
    }
    let (xPrev, _) = xPrevAndPredX0(x: x, et: etPrime, alpha: alpha, alphaPrev: alphaPrev)
    x = xPrev
    oldEps.append(et)
    if oldEps.count > 3 {
      oldEps.removeFirst()
    }
  }
  let z = 1.0 / scaleFactor * x
  let img = decoder(inputs: z)[0].as(of: Float.self).toCPU()
  print("Total time \(Date().timeIntervalSince(startTime))")
  let image = ccv_dense_matrix_new(
    Int32(startHeight * 8), Int32(startWidth * 8), Int32(CCV_8U | CCV_C3), nil, 0)
  // I have better way to copy this out (basically, transpose and then ccv_shift). Doing this just for fun.
  for y in 0..<startHeight * 8 {
    for x in 0..<startWidth * 8 {
      let (r, g, b) = (img[0, 0, y, x], img[0, 1, y, x], img[0, 2, y, x])
      image!.pointee.data.u8[y * startWidth * 8 * 3 + x * 3] = UInt8(
        min(max(Int(Float((r + 1) / 2) * 255), 0), 255))
      image!.pointee.data.u8[y * startWidth * 8 * 3 + x * 3 + 1] = UInt8(
        min(max(Int(Float((g + 1) / 2) * 255), 0), 255))
      image!.pointee.data.u8[y * startWidth * 8 * 3 + x * 3 + 2] = UInt8(
        min(max(Int(Float((b + 1) / 2) * 255), 0), 255))
    }
  }
  let _ = (workDir + "/txt2img.png").withCString {
    ccv_write(image, UnsafeMutablePointer(mutating: $0), nil, Int32(CCV_IO_PNG_FILE), nil)
  }
}
