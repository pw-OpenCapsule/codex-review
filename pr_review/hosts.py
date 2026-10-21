"""Host names that reach the same Gogs instance. Standard library only: credential_helper.py imports it."""
# 2026-10-13 起公司 Gogs 改走公网入口 sg-git-src；旧名解析到内网后不可达，但凭证文件可能仍写旧名。
SAME_GOGS=({'sg-git-src.pwtk.cc','sg-git.pwtk.cc','sg-cy-git.caminonode.com','sg-git.port888.com'},)

def same_gogs_host(a,b):
    return a==b or any(a in group and b in group for group in SAME_GOGS)
