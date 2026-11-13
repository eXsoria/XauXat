#!/usr/bin/env python3
"""Export the KoeAI LLVC checkpoint as a fixed-size Core ML streaming step."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
from types import MethodType

import coremltools as ct
import numpy as np
import torch


INPUTS = ("audio", "encoder", "decoder", "synthesis", "prenet")
OUTPUTS = ("converted", "encoder_next", "decoder_next", "synthesis_next", "prenet_next")
CHECKPOINT_SHA256 = "cceb7ab9621f84d62d283725ae3281cacb04f762d6a088fe3e97c1a29d4b8c0e"


class StreamingStep(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, audio, encoder, decoder, synthesis, prenet):
        return self.model(audio, encoder.clone(), decoder.clone(), synthesis, prenet.clone(), pad=False)


def export_prenet(self, audio, state):
    next_state = []
    for index, layer in enumerate(self.down_convs):
        start, length = self.buf_indices[index], self.buf_lengths[index]
        joined = torch.cat((state[..., start:start + length], audio), dim=-1)
        next_state.append(joined[..., -length:])
        audio = layer(joined)
    return audio, torch.cat(next_state, dim=-1)


def export_encoder(self, audio, state):
    next_state = []
    for index, layer in enumerate(self.dcc_layers):
        start, length = self.buf_indices[index], self.buf_lengths[index]
        joined = torch.cat((state[..., start:start + length], audio), dim=-1)
        next_state.append(joined[..., -length:])
        audio = audio + layer(joined)
    return audio, torch.cat(next_state, dim=-1)


def export_decoder(self, target, memory, state):
    # One decoder chunk: unfolding the context and chunk produces one window.
    memory = torch.cat((state[:, 0], memory.transpose(1, 2)), dim=1)
    next_state = [memory[:, -self.ctx_len:]]
    if self.use_pos_enc:
        memory = memory + self.pos_enc(memory)
    target = target.transpose(1, 2)
    for index, layer in enumerate(self.tf_dec_layers):
        target = torch.cat((state[:, index + 1], target), dim=1)
        next_state.append(target[:, -self.ctx_len:])
        if self.use_pos_enc and index == 0:
            target = target + self.pos_enc(target)
        target, _, _ = layer(target, memory, self.chunk_size)
    return target.transpose(1, 2), torch.stack(next_state, dim=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
        parser.error("Unexpected KoeAI checkpoint SHA-256")
    sys.path.insert(0, str(args.upstream.resolve()))
    from model import Net

    torch.set_num_threads(1)
    torch.backends.mha.set_fastpath_enabled(False)
    config = json.loads((args.upstream / "experiments/llvc/config.json").read_text())
    model = Net(**config["model_params"]).eval()
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True)["model"])
    step = StreamingStep(model).eval()
    chunk = model.L * model.dec_chunk_size
    context = 2 * model.L
    if (chunk, context, config["data"]["sr"]) != (208, 32, 16000):
        raise ValueError("Unexpected LLVC audio contract")

    generator = torch.Generator().manual_seed(4)
    audio = torch.rand(1, 1, 20 * chunk, generator=generator) * 0.2 - 0.1
    initial = (*model.init_buffers(1, torch.device("cpu")), model.convnet_pre.init_ctx_buf(1, torch.device("cpu")))
    example = (torch.zeros(1, 1, chunk + context), *initial)
    export_model = copy.deepcopy(model)
    # Core ML cannot translate the upstream assignments into tensor slices.
    # Export equivalent concatenations and verify against the original model.
    export_model.convnet_pre.forward = MethodType(export_prenet, export_model.convnet_pre)
    export_model.mask_gen.encoder.forward = MethodType(export_encoder, export_model.mask_gen.encoder)
    export_model.mask_gen.decoder.forward = MethodType(export_decoder, export_model.mask_gen.decoder)
    with torch.inference_mode():
        traced = torch.jit.trace(StreamingStep(export_model).eval(), example)
        exported = ct.convert(
            traced,
            inputs=[ct.TensorType(name=name, shape=value.shape, dtype=np.float32) for name, value in zip(INPUTS, example)],
            outputs=[ct.TensorType(name=name, dtype=np.float32) for name in OUTPUTS],
            minimum_deployment_target=ct.target.iOS15,
            compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        eager_state = initial
        coreml_state = [value.numpy().copy() for value in initial]
        previous = example[0][..., :context]
        max_error = 0
        for block in audio.split(chunk, dim=-1):
            window = torch.cat((previous, block), dim=-1)
            expected, *eager_state = step(window, *eager_state)
            actual = exported.predict(dict(zip(INPUTS, (window.numpy(), *coreml_state))))
            np.testing.assert_allclose(actual["converted"], expected.numpy(), atol=0.0002, rtol=0.002)
            max_error = max(max_error, float(np.max(np.abs(actual["converted"] - expected.numpy()))))
            coreml_state = [actual[name] for name in OUTPUTS[1:]]
            previous = block[..., -context:]
        print(f"Core ML / PyTorch parity on 20 sequential blocks, maximum PCM error {max_error:.8f}")

    exported.author = "KoeAI"
    exported.license = "MIT"
    exported.short_description = "KoeAI LLVC G_500000, 16 kHz mono streaming voice conversion"
    exported.save(str(args.output))


if __name__ == "__main__":
    main()
