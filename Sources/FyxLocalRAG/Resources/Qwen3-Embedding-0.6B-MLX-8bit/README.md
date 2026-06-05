---
library_name: mlx-embeddings
tags:
- mlx
- mlx-embeddings
- embeddings
- sentence-similarity
- feature-extraction
- quantized
- 8bit
- qwen
- qwen3
- qwen3-embedding
base_model: Qwen/Qwen3-Embedding-0.6B
license: apache-2.0
pipeline_tag: feature-extraction
language:
- en
- zh
- multilingual
---

# Qwen3-Embedding-0.6B MLX 8-bit

MLX 8-bit quantization of [Qwen/Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B), produced with [mlx-embeddings](https://github.com/Blaizzy/mlx-embeddings) on Apple Silicon.

## What is this?

Qwen3-Embedding is a decoder-only LLM-style text embedding model from the Qwen3 family, using last-token pooling to produce dense vector representations. It scores near the top of MMTEB multilingual benchmarks while retaining Apache-2.0 licensing.

## Quantization

- Method: MLX affine quantization (`mlx_embeddings.convert`), group_size=64
- Bits per weight: 8
- Output size: **617 MB** (vs ~1.2 GB for bf16 source)

## Quickstart

```python
from mlx_embeddings import load

model, tokenizer = load("majentik/Qwen3-Embedding-0.6B-MLX-8bit")

inputs = tokenizer(
    ["What is the capital of France?", "Paris is the capital of France."],
    padding=True, truncation=True, return_tensors="mlx"
)
outputs = model(inputs["input_ids"], attention_mask=inputs["attention_mask"])
embeddings = outputs.text_embeds  # already L2-normalised, shape [batch, dim]
```

For sentence similarity:

```python
import mlx.core as mx

e = embeddings
scores = (e[0] @ e[1:].T).tolist()
print(scores)
```

## Model Specifications

| Property | Value |
|---|---|
| Base Model | [Qwen/Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) |
| Architecture | Decoder-only (Qwen3ForCausalLM) with last-token pooling |
| Parameters | 0.6B (596M) (pre-quantization) |
| Context Length | 32K |
| Embedding Dim | 1024 |
| BF16 Size | ~1.2 GB |
| License | apache-2.0 |
| Languages | 100+ (multilingual) |

## License

Apache 2.0 — inherited from the upstream Qwen3-Embedding model. Free for research and commercial use.

## See also

- Base: [Qwen/Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- Official GGUF: [Qwen/Qwen3-Embedding-0.6B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF) (if published by Qwen)
- mlx-embeddings package: https://github.com/Blaizzy/mlx-embeddings
- Garden hub: [majentik/garden](https://huggingface.co/majentik/garden)
- MTEB leaderboard: https://huggingface.co/spaces/mteb/leaderboard
