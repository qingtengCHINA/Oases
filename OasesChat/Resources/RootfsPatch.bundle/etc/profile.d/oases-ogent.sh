export OGENT_ROOT=/root/.ogent
export MINIS_ROOT=/root/.ogent
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PAGER=cat
export EDITOR=vi
export PS1='root@ogent:\w# '
cd /root 2>/dev/null || cd /
# Preinstalled toolchain defaults (mirrors ISHExecutionCoordinator's shell env).
export UV_PYTHON_DOWNLOADS=never
export UV_PYTHON_PREFERENCE=only-system
export UV_LINK_MODE=copy
export PIP_BREAK_SYSTEM_PACKAGES=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
