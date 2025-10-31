# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

wf-human-variation is a Nextflow DSL2 workflow for comprehensive analysis of human genomic variation from Oxford Nanopore Technologies sequencing data. The workflow consolidates multiple variant calling approaches into a single pipeline:

- **SNP calling** (Clair3): Small variant detection (SNVs and indels)
- **SV calling** (Sniffles2): Structural variant detection
- **CNV calling** (Spectre/QDNAseq): Copy number variant detection
- **STR genotyping** (Straglr): Short tandem repeat expansion analysis
- **Modified base calling** (modkit): DNA methylation and modification detection

Each analysis is a modular sub-workflow that can be enabled independently via command-line flags.

## Development Commands

### Running the Workflow

Basic workflow execution (requires Nextflow >=23.04.2):
```bash
# Run with Docker
nextflow run main.nf \
    --bam <path_to_bam> \
    --ref <reference_fasta> \
    --sample_name <sample> \
    --snp --sv --mod \
    -profile standard

# Run with demo data
wget https://ont-exd-int-s3-euwst1-epi2me-labs.s3.amazonaws.com/wf-human-variation/hg002%2bmods.v1/wf-human-variation-demo.tar.gz
tar -xzvf wf-human-variation-demo.tar.gz
nextflow run main.nf \
    --bam wf-human-variation-demo/demo.bam \
    --ref wf-human-variation-demo/demo.fasta \
    --bed wf-human-variation-demo/demo.bed \
    --sample_name DEMO \
    --snp --sv --mod --phased \
    -profile standard
```

### Testing and CI

Tests run via GitLab CI (see [.gitlab-ci.yml](.gitlab-ci.yml)):
```bash
# The CI runs the workflow with test data for multiple configurations
# Each test matrix entry exercises different combinations of sub-workflows
# Example test configurations: all_phased, snp_sv_mod_unphased, str-usersex, etc.

# CI test data is downloaded automatically:
# https://ont-exd-int-s3-euwst1-epi2me-labs.s3.amazonaws.com/wf-human-variation/snp_demo.tar.gz
```

### Linting

Python code linting with flake8:
```bash
# Install pre-commit hooks (recommended)
pre-commit install

# Run flake8 manually
flake8 bin \
    --import-order-style=google \
    --statistics \
    --max-line-length=88 \
    --per-file-ignores=bin/workflow_glue/models/*:NT001
```

### Documentation

Documentation is auto-generated from [docs/](docs/) markdown files:
```bash
# The pre-commit hook runs this automatically to update README.md
parse_docs -p docs -e .md \
    -s 01_brief_description 02_introduction 03_compute_requirements 04_install_and_run \
       05_related_protocols 06_input_example 06_input_parameters 07_outputs \
       08_pipeline_overview 09_troubleshooting 10_FAQ 11_other \
    -ot README.md -od output_definition.json -ns nextflow_schema.json
```

### Model Schema Updates

```bash
# Update the Clair3 model schema when new models are added
bash util/update_models_schema.sh . docker
```

## Architecture

### High-Level Structure

```
main.nf                  # Entry point, orchestrates all sub-workflows
├── workflows/           # Sub-workflow definitions
│   ├── wf-human-snp.nf       # Clair3 SNP calling workflow
│   ├── wf-human-sv.nf        # Sniffles2 SV calling workflow
│   ├── wf-human-cnv.nf       # Spectre CNV calling workflow
│   ├── wf-human-cnv-qdnaseq.nf  # QDNAseq CNV calling workflow
│   ├── wf-human-str.nf       # Straglr STR genotyping workflow
│   ├── methyl.nf             # Modkit modified base calling workflow
│   └── partners.nf           # Partner integration outputs
├── modules/local/       # Process definitions for sub-workflows
│   ├── common.nf             # Shared processes (coverage, alignment, etc.)
│   └── wf-human-*.nf         # Sub-workflow-specific processes
├── lib/                 # Groovy library code
│   ├── _ingress.nf           # BAM/uBAM input handling and alignment
│   ├── reference.nf          # Reference genome preparation
│   ├── model.nf              # Basecaller model detection
│   └── common.nf             # Shared parameter utilities
└── bin/                 # Executable scripts
    ├── workflow_glue/        # Python module for report generation and utilities
    └── *.py                  # Standalone helper scripts
```

### Workflow Execution Flow

1. **Input Validation & Preparation** ([main.nf](main.nf:84-200))
   - Validate parameters and check for conflicting options
   - Prepare reference genome (index, cache)
   - Handle BAM input (aligned or unaligned) via `ingress`
   - Detect basecaller model for Clair3 model selection

2. **Data QC & Pre-processing** ([modules/local/common.nf](modules/local/common.nf))
   - Calculate coverage with `mosdepth`
   - Check minimum coverage threshold (`--bam_min_coverage`, default: 20x)
   - Optional downsampling to target coverage (`--downsample_coverage_target`, default: 60x)
   - Compute read statistics with `fastcat`

3. **Parallel Sub-workflow Execution**
   - **SNP** (enabled with `--snp`): Chunked parallel variant calling
   - **SV** (enabled with `--sv`): Structural variant detection
   - **CNV** (enabled with `--cnv`): Copy number analysis
   - **STR** (enabled with `--str`): Requires `--snp` for haplotagging
   - **MOD** (enabled with `--mod`): Requires MM/ML BAM tags

4. **Optional Phasing** (enabled with `--phased`)
   - Uses whatshap for variant phasing
   - Generates haplotagged BAM for downstream analysis
   - Phasing affects SNP, SV, and MOD outputs depending on enabled sub-workflows

5. **Annotation & Reporting**
   - SnpEff annotation (human hg19/hg38 only, disable with `--annotation false`)
   - ClinVar annotation for SNPs
   - HTML reports per sub-workflow
   - IGV visualization support (with `--igv`)

### Key Design Patterns

#### Sub-workflow Modularity

Each sub-workflow follows a consistent pattern:
- **Workflow definition** in `workflows/wf-human-*.nf` (orchestration)
- **Process definitions** in `modules/local/wf-human-*.nf` (atomic tasks)
- **Output function** in `modules/local/wf-human-*.nf` (publishing results)
- **Report generation** in `bin/workflow_glue/report_*.py` (Python)

#### Conditional Workflow Execution

The main workflow intelligently enables sub-workflows based on dependencies:
- `--str` automatically enables `--snp` (requires haplotagged BAM)
- `--cnv` with Spectre automatically enables `--snp` (requires phased variants)
- `--phased` with `--sv` enables `--snp` (SV phasing requires haplotagged reads)

#### Chromosome Handling

By default, variants are called only on standard chromosomes (chr1-22, X, Y, MT). Use `--include_all_ctgs` to process all reference contigs.

#### File Format Handling

- Input can be aligned BAM/CRAM or unaligned BAM (uBAM)
- Output format controlled by `--output_xam_fmt` (cram or bam)
- QDNAseq CNV caller forces BAM output (overrides CRAM selection)

### Python Module Organization

The `bin/workflow_glue/` module contains:
- **Report generators**: `report_*.py` files create HTML reports using ezcharts
- **Utilities**: `util.py`, `combine_jsons.py`, etc.
- **Validators**: `check_*.py` files for input validation
- **Models**: `models/` directory defines data structures
- **Helpers**: `wfg_helpers/` contains reusable functions

### Important Constraints

1. **Genome builds**: Most features require hg19/GRCh37 or hg38/GRCh38
   - STR calling requires hg38 only
   - CNV calling (Spectre/QDNAseq) requires hg19 or hg38
   - Non-human genomes require `--annotation false --include_all_ctgs`

2. **Coverage requirements**:
   - Minimum 20x coverage (configurable via `--bam_min_coverage`)
   - Recommended 30x+ for optimal performance

3. **Modified base calling**:
   - Requires MM/ML tags in input BAM
   - Workflow auto-detects tags and skips MOD if absent

4. **Phasing overhead**:
   - Phasing approximately doubles runtime
   - Significantly increases storage requirements (terabyte scale)

### Configuration Files

- [nextflow.config](nextflow.config): Main workflow parameters and defaults
- [base.config](base.config): Resource allocation and executor settings
- [nextflow_schema.json](nextflow_schema.json): Parameter schema (auto-generated)
- [.gitlab-ci.yml](.gitlab-ci.yml): CI/CD test matrix definitions

### Partner Integrations

The workflow supports output formatting for tertiary analysis partners:
- Geneyx
- Fabric

Enable with `--partner <name>` to generate partner-specific outputs.
