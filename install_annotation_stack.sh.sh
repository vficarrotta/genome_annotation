#!/usr/bin/env bash
set -Eeuo pipefail

### ------- locations (match your current layout) -------
PREFIX="/home/vzf0010/apps"

# Core tool homes (already installed on your side)
AGAT_HOME="$PREFIX/AGAT_src"
EVM_PERL="$PREFIX/evm-perl"               # EVM’s self-contained Perl (Perl 5.32)
AGAT_PERL5="$PREFIX/agat-perl5"           # local::lib for AGAT-only Perl deps

# eggNOG-mapper
EGGNOG_VENV="$PREFIX/eggnog-venv"
EGGNOG_DATA_DIR="/mmfs1/scratch/vzf0010/eggnog_db"

# Liftoff (via a small conda env)
LIFTOFF_CONDA="$PREFIX/liftoff-conda"

# Other tools you already installed
GFFREAD_HOME="$PREFIX/gffread"            # /home/.../gffread/bin/gffread
MINIPROT_HOME="$PREFIX/miniprot"          # /home/.../miniprot/bin/miniprot
INFERNAL_HOME="$PREFIX/infernal"          # (cmscan lives here if built with Infernal)
TRNASCAN_HOME="$PREFIX/trnascan-se"       # /home/.../trnascan-se/bin/tRNAscan-SE

# Module for site-wide conda shim (don’t fail if modules aren’t available)
module load python/anaconda/3.11.7 2>/dev/null || true

# General shell hygiene
umask 022
unset PYTHONPATH

mkdir -p "$AGAT_PERL5" "$EGGNOG_DATA_DIR"

grn(){ printf "\033[32m%s\033[0m\n" "$*"; }
ylw(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

# Small helper: run a command or explain and exit
must() {
  "$@" || { red "FAILED: $*"; exit 1; }
}

echo "== [1/5] eggNOG-mapper venv =="
if [[ ! -x "$EGGNOG_VENV/bin/python" ]]; then
  python3 -m venv "$EGGNOG_VENV"
fi

# Pin the exact working combo you verified
# (Biopython 1.81, psutil 5.9.8, numpy 1.26.4, XlsxWriter 1.4.3)
"$EGGNOG_VENV/bin/pip" install --upgrade pip wheel setuptools >/dev/null
"$EGGNOG_VENV/bin/pip" install \
  "eggnog-mapper==2.1.13" \
  "biopython==1.81" \
  "psutil==5.9.8" \
  "numpy==1.26.4" \
  "XlsxWriter==1.4.3"

# Don’t force DB downloads if they exist
for f in eggnog.db eggnog.taxa.db eggnog_proteins.dmnd; do
  if [[ -s "$EGGNOG_DATA_DIR/$f" ]]; then
    grn "eggNOG DB present: $f"
  else
    ylw "eggNOG DB MISSING: $f  (you can fetch later into $EGGNOG_DATA_DIR)"
  fi
done

echo "== [2/5] Liftoff conda env =="
# Create a small env with liftoff + minimap2 (gffread you already installed by hand)
# Bioconda tends to be happiest with python 3.10 here
if [[ ! -x "$LIFTOFF_CONDA/bin/python" ]]; then
  must conda create -y -p "$LIFTOFF_CONDA" -c conda-forge -c bioconda \
    "python=3.10" "liftoff=1.6.3" "minimap2"  # liftoff drags its own deps
else
  ylw "liftoff-conda already exists; skipping create"
fi

# Smoke tests (don’t fail the whole install if not found)
if "$LIFTOFF_CONDA/bin/liftoff" -h >/dev/null 2>&1; then
  grn "Liftoff OK"
else
  ylw "Liftoff not runnable yet (check conda init/module on this node?)"
fi
if "$LIFTOFF_CONDA/bin/minimap2" --version >/dev/null 2>&1; then
  grn "minimap2 in liftoff-conda OK"
fi

echo "== [3/5] AGAT deps under EVM Perl (pure-Perl only) =="
# Install a small, safe set with the SAME perl that will run AGAT
# Avoid XS trouble: use pure-Perl YAML rather than YAML::XS, and add LWP stack
# Also add Sort::Naturally (you saw that error earlier).
curl -sL https://cpanmin.us | "$EVM_PERL/bin/perl" - -L "$AGAT_PERL5" --notest \
  Try::Tiny LWP HTTP::Message URI JSON YAML YAML::Tiny Sort::Naturally

# OPTIONAL (can build XS; harmless if it fails): SSL stack for LWP over HTTPS
# If it fails to compile on your node, we just continue.
curl -sL https://cpanmin.us | "$EVM_PERL/bin/perl" - -L "$AGAT_PERL5" --notest \
  IO::Socket::SSL Net::SSLeay Mozilla::CA || true

# Provide a tiny shim for Term::ProgressBar to dodge XS deps
mkdir -p "$AGAT_PERL5/lib/perl5/Term"
cat > "$AGAT_PERL5/lib/perl5/Term/ProgressBar.pm" <<'PERL'
package Term::ProgressBar;
our $VERSION = '2.22';
sub import { 1 }
sub new {
  my ($class, $arg) = @_; $arg ||= {};
  bless { target => $arg->{count}//$arg->{target}//0, count => 0 }, $class
}
sub update { 1 }
sub message { 1 }
sub minor   { 1 }
sub next    { 1 }
sub target  { my $s=shift; $s->{target} = shift if @_; $s->{target} }
1;
PERL

# Smoke test: AGAT banner in a scrubbed env (no site Perl/conda bleeding in)
if env -i \
   PATH="$EVM_PERL/bin:$AGAT_HOME/bin:/usr/bin:/bin" LC_ALL=C LANG=C HOME="$HOME" \
   PERL5LIB="$EVM_PERL/lib/site_perl:$AGAT_HOME/lib:$AGAT_PERL5/lib/perl5:$AGAT_PERL5/lib/perl5/x86_64-linux-thread-multi" \
   agat_sp_statistics.pl --help >/dev/null 2>&1; then
  grn "AGAT runs under EVM Perl with local deps"
else
  ylw "AGAT did not start; re-source env later and check PERL5LIB/PATH."
fi

echo "== [4/5] Write env_annotation_tools.sh =="
ENVFILE="$PREFIX/env_annotation_tools.sh"
cat > "$ENVFILE" <<'BASH'
# /home/vzf0010/apps/env_annotation_tools.sh
# Load site conda shim if available
module load python/anaconda/3.11.7 2>/dev/null || true

# Calm conda; prefer classic solver; avoid random plugins
export CONDA_SOLVER=classic
export CONDA_NO_PLUGINS=1
export CONDA_PKGS_DIRS="$HOME/.conda/pkgs"

# Neutral locale to avoid "C.UTF-8" warning on these nodes
export LC_ALL=C
export LANG=C

# Avoid leaking site python into tools that shell to python
unset PYTHONPATH

# --- Paths to local installs ---
export PREFIX="/home/vzf0010/apps"
export AGAT_HOME="$PREFIX/AGAT_src"
export EVM_PERL="$PREFIX/evm-perl"
export AGAT_PERL5="$PREFIX/agat-perl5"

export EGGNOG_VENV="$PREFIX/eggnog-venv"
export EGGNOG_DATA_DIR="/mmfs1/scratch/vzf0010/eggnog_db"

export LIFTOFF_CONDA="$PREFIX/liftoff-conda"
export GFFREAD_HOME="$PREFIX/gffread"
export MINIPROT_HOME="$PREFIX/miniprot"
export INFERNAL_HOME="$PREFIX/infernal"
export TRNASCAN_HOME="$PREFIX/trnascan-se"

# PATH (order chosen to keep system python default; emapper is still found)
# If you WANT venv python to be default, move $EGGNOG_VENV/bin to the front.
export PATH="$EVM_PERL/bin:$AGAT_HOME/bin:$LIFTOFF_CONDA/bin:$GFFREAD_HOME/bin:$MINIPROT_HOME/bin:$INFERNAL_HOME/bin:$TRNASCAN_HOME/bin:$EGGNOG_VENV/bin:$PATH"

# PERL5LIB for AGAT (EVM site_perl -> AGAT libs -> local::lib generic+arch)
export PERL5LIB="$EVM_PERL/lib/site_perl:$AGAT_HOME/lib:$AGAT_PERL5/lib/perl5:$AGAT_PERL5/lib/perl5/x86_64-linux-thread-multi"

# eggNOG expects this for DB lookup
export EGGNOG_DATA_DIR
BASH
grn "Wrote $ENVFILE"

echo "== [5/5] Friendly reminders =="
if command -v diamond >/dev/null 2>&1; then
  grn "diamond found: $(diamond version 2>&1 | head -n1 || true)"
else
  ylw "diamond not on PATH; emapper requires DIAMOND or MMseqs2 (Diamond recommended)."
fi

ylw "To use the stack now:  source $ENVFILE"

####### SANITY CHECK 
# AGAT banner (uses shimmed Term::ProgressBar)
env -i \
  PATH="/home/vzf0010/apps/evm-perl/bin:/home/vzf0010/apps/AGAT_src/bin:/usr/bin:/bin" HOME="$HOME" LC_ALL=C LANG=C \
  PERL5LIB="/home/vzf0010/apps/evm-perl/lib/site_perl:/home/vzf0010/apps/AGAT_src/lib:/home/vzf0010/apps/agat-perl5/lib/perl5:/home/vzf0010/apps/agat-perl5/lib/perl5/x86_64-linux-thread-multi" \
  agat_sp_statistics.pl --help | head -n 5

# Liftoff (conda)
/home/vzf0010/apps/liftoff-conda/bin/liftoff -h | head -n1

# Core tools you already have
for x in minimap2 gffread miniprot cmscan tRNAscan-SE; do
  printf "%-12s -> %s\n" "$x" "$(command -v $x || echo MISSING)"
done

# emapper + DBs
emapper.py --version || true
for f in eggnog.db eggnog.taxa.db eggnog_proteins.dmnd; do
  test -s "$EGGNOG_DATA_DIR/$f" && echo "OK: $f" || echo "MISSING: $f"
done

##### Sanity check annotation pipeline dependencies
set -euo pipefail
echo "== PATH checks =="

# Liftoff (use the env you actually have)
if [ -x "/home/vzf0010/apps/liftoff-conda/bin/liftoff" ]; then
  /home/vzf0010/apps/liftoff-conda/bin/liftoff -h | head -n1
else
  echo "MISSING: /home/vzf0010/apps/liftoff-conda/bin/liftoff"
fi

for x in minimap2 gffread miniprot cmscan tRNAscan-SE emapper.py; do
  printf "%-12s -> %s\n" "$x" "$(command -v "$x" || echo MISSING)"
done

echo "== eggNOG DB files =="
for f in eggnog.db eggnog.taxa.db eggnog_proteins.dmnd; do
  test -s "$EGGNOG_DATA_DIR/$f" && echo "OK: $f" || echo "MISSING: $f"
done

echo "== AGAT banner =="
env -i \
  PATH="/home/vzf0010/apps/evm-perl/bin:/home/vzf0010/apps/AGAT_src/bin:/usr/bin:/bin" HOME="$HOME" LC_ALL=C LANG=C \
  PERL5LIB="/home/vzf0010/apps/evm-perl/lib/site_perl:/home/vzf0010/apps/AGAT_src/lib:/home/vzf0010/apps/agat-perl5/lib/perl5:/home/vzf0010/apps/agat-perl5/lib/perl5/x86_64-linux-thread-multi" \
  agat_sp_statistics.pl --help | head -n 5

PYBIN="$EGGNOG_VENV/bin/python"
[ -x "$PYBIN" ] || PYBIN="$EGGNOG_VENV/bin/python3"

echo "== Python libs (eggnog venv) =="
echo "PYTHON USED: $PYBIN"
"$PYBIN" - <<'PY'
import sys
mods=[]
for m in ("Bio","psutil","numpy","xlsxwriter"):
    try:
        mod=__import__(m); mods.append(f"{m}:{getattr(mod,'__version__','?')}")
    except Exception as e:
        print(f"{m} IMPORT FAIL:", e)
print("Python", sys.version.split()[0], "|", ", ".join(mods))
PY


################# NOTES ####################
# Notes & coverage checklist (what this script ensures)
# 
# eggNOG-mapper (emapper.py)
# 
# Installs in eggnog-venv with: Biopython 1.81, psutil 5.9.8, numpy 1.26.4, XlsxWriter 1.4.3 (the versions you validated).
# 
# Uses your DB at /mmfs1/scratch/vzf0010/eggnog_db (no forced re-download).
# 
# Leaves MMseqs2 optional; Diamond is preferred (script warns if missing).
# 
# Liftoff + minimap2
# 
# Creates /home/vzf0010/apps/liftoff-conda with liftoff=1.6.3 and minimap2 via conda-forge/bioconda.
# 
# You already have gffread outside conda; PATH includes both.
# 
# AGAT
# 
# Runs AGAT under the EVM perl with an AGAT-only local::lib (agat-perl5).
# 
# Installs only pure-Perl deps: Try::Tiny, LWP, HTTP::Message, URI, JSON, YAML, YAML::Tiny, Sort::Naturally.
# 
# Provides a tiny Term::ProgressBar shim to avoid troublesome XS builds.
# 
# Scrubbed-env smoke test included.
# 
# Other tools (already installed)
# 
# PATH hooks in gffread, miniprot, infernal/cmscan, tRNAscan-SE.
# 
# Locale set to C to avoid C.UTF-8 warnings.
# 
# env file
# 
# Writes /home/vzf0010/apps/env_annotation_tools.sh with the right PATH/PERL5LIB and variables.