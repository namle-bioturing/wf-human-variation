# Parabricks DeepVariant Integration

## Overview

This integration adds support for NVIDIA Parabricks DeepVariant as an alternative to Clair3 for SNP calling in wf-human-variation.

## Changes Made

### 1. New Workflow File
- **File**: `workflows/wf-human-snp-parabricks.nf`
- **Purpose**: Simplified workflow using Parabricks DeepVariant instead of Clair3's two-network approach
- **Key Features**:
  - Single-step variant calling with `pbrun deepvariant`
  - Optional phasing with whatshap
  - Optional haplotagging for STR/MOD workflows
  - Compatible outputs with Clair3 workflow (drop-in replacement)

### 2. Main Workflow Updates
- **File**: `main.nf`
- **Changes**:
  - Added conditional import: `snp_clair3` vs `snp_parabricks`
  - Added logic to choose variant caller based on `--use_parabricks` flag
  - Clair3 model detection only runs when using Clair3

### 3. Configuration Files

#### nextflow.config
Added new parameters:
```groovy
use_parabricks = false  // Enable Parabricks DeepVariant
pbrun_threads = 32      // CPU threads for Parabricks
```

#### base.config
Added Parabricks process label:
```groovy
withLabel:parabricks {
    container = "nvcr.io/nvidia/clara/clara-parabricks:4.3.0-1"
    cpus = 32
    memory = "64 GB"
}
```

Added GPU support for both Docker and Singularity profiles.

## Usage

### Basic Usage (Clair3 - Default)
```bash
nextflow run main.nf \
    --snp \
    --bam input.bam \
    --ref reference.fa \
    --sample_name SAMPLE
```

### Using Parabricks DeepVariant
```bash
nextflow run main.nf \
    --snp \
    --use_parabricks \
    --bam input.bam \
    --ref reference.fa \
    --sample_name SAMPLE
```

### With Phasing
```bash
nextflow run main.nf \
    --snp \
    --use_parabricks \
    --phased \
    --bam input.bam \
    --ref reference.fa \
    --sample_name SAMPLE
```

### With STR Genotyping
```bash
nextflow run main.nf \
    --snp \
    --use_parabricks \
    --str \
    --bam input.bam \
    --ref reference.fa \
    --sample_name SAMPLE \
    --sex XY
```

### Custom Thread Count
```bash
nextflow run main.nf \
    --snp \
    --use_parabricks \
    --pbrun_threads 64 \
    --bam input.bam \
    --ref reference.fa
```

## Architecture Comparison

### Clair3 Workflow (Original)
```
BAM → make_chunks → pileup_variants (parallel) → aggregate
                  ↓
             phase_contig
                  ↓
      evaluate_candidates (parallel) → merge → final VCF
```
- **Pros**: Optimized for ONT data, highly accurate
- **Cons**: Complex multi-step process, slower

### Parabricks DeepVariant Workflow (New)
```
BAM → pbrun_deepvariant → VCF
                ↓
         (optional) phase_deepvariant → phased VCF
                ↓
         (optional) haplotag_bam → haplotagged BAM
```
- **Pros**: Simpler pipeline, GPU-accelerated, faster on GPU systems
- **Cons**: Not specifically optimized for ONT, requires GPU

## Outputs

Both workflows produce compatible outputs:

| Output | Clair3 | Parabricks |
|--------|--------|------------|
| VCF file | ✅ | ✅ |
| Phased VCF (with `--phased`) | ✅ | ✅ |
| Haplotagged BAM (with `--phased`) | ✅ | ✅ |
| gVCF (with `--GVCF`) | ✅ | ✅ |
| Per-contig BAMs for STR | ✅ | ✅ |
| HTML Report | ✅ | ✅ |

## Requirements

### Clair3 (Default)
- CPU-based (no GPU required)
- ONT basecaller model detection
- Container: `ontresearch/wf-human-variation-snp`

### Parabricks DeepVariant
- **GPU required** (NVIDIA GPU with CUDA support)
- No model detection needed
- Container: `nvcr.io/nvidia/clara/clara-parabricks:4.3.0-1`
- Recommended: 32+ CPU cores, 64+ GB RAM, 1+ NVIDIA GPU

## GPU Configuration

The integration automatically configures GPU access:

**Docker**:
```groovy
process."withLabel:parabricks".containerOptions = "--gpus all"
```

**Singularity**:
```groovy
process."withLabel:parabricks".containerOptions = "--nv"
```

## Performance Considerations

- **Parabricks** is faster on GPU-equipped systems (5-10x speedup)
- **Clair3** may be more accurate for ONT-specific error modes
- For cloud/HPC without GPUs, use Clair3
- For GPU-enabled systems, Parabricks offers better throughput

## Compatibility

The Parabricks workflow maintains full compatibility with downstream workflows:
- ✅ SV calling (`--sv`)
- ✅ STR genotyping (`--str`)
- ✅ Modified base calling (`--mod`)
- ✅ CNV calling (`--cnv`)
- ✅ Annotation with SnpEff
- ✅ ClinVar annotations

## Troubleshooting

### No GPU Available
If you get GPU errors, ensure:
1. NVIDIA GPU is present: `nvidia-smi`
2. Docker has GPU access: `docker run --gpus all nvidia/cuda:11.0-base nvidia-smi`
3. Use `--use_parabricks false` to fall back to Clair3

### Container Pull Issues
```bash
# Pre-pull the Parabricks container
docker pull nvcr.io/nvidia/clara/clara-parabricks:4.3.0-1
```

### Memory Issues
Increase memory allocation:
```bash
# In base.config, modify:
withLabel:parabricks {
    memory = "128 GB"  # Increase if needed
}
```

## Future Enhancements

Potential improvements:
1. Add Parabricks-specific quality metrics to reports
2. Support for Parabricks Freebayes mode
3. Benchmark comparison between Clair3 and DeepVariant on ONT data
4. Auto-detection of GPU availability
