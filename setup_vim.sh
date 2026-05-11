#!/bin/bash
# ============================================================
#  setup_vim.sh
#  Vim 전체 기능 자동화 설정 스크립트
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  포함 항목:
#   1. vim / vim-gtk3 설치 (클립보드 지원 포함)
#   2. vim-plug 플러그인 매니저 설치
#   3. 플러그인: NERDTree, fzf, vim-airline, coc.nvim 등
#   4. .vimrc 자동 구성 (문법강조, 줄번호, 탭, 마우스 등)
#   5. 색상 테마 (gruvbox)
#   6. coc.nvim 언어서버 (LSP) 설정
# ============================================================

set -euo pipefail

# ── 색상 헬퍼 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
skip()    { echo -e "        ${YELLOW}↷ skip${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 확인 ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "sudo 로 실행하세요:  sudo bash $0"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

info "대상 사용자: $REAL_USER ($REAL_HOME)"

# ── 프록시 환경변수 로드 (setup_proxy.sh 적용 환경 대응) ──────
if [[ -f /etc/environment ]]; then
  set +u
  # /etc/environment 에서 proxy 관련 변수만 추출해 export
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' "')
    val=$(echo "$val" | tr -d '"')
    case "$key" in
      http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY)
        export "$key"="$val" ;;
    esac
  done < /etc/environment
  set -u
  [[ -n "${HTTP_PROXY:-}" ]] && info "프록시 감지: $HTTP_PROXY"
fi

# ════════════════════════════════════════════════════════════
# [1] vim 설치 (클립보드 지원 포함)
# ════════════════════════════════════════════════════════════
section "[1] vim 설치"

apt-get update -y
# vim-gtk3: +clipboard, +xterm_clipboard 지원
if apt-get install -y vim vim-gtk3 curl git 2>/dev/null; then
  success "vim-gtk3 설치 완료 (클립보드 지원)"
else
  apt-get install -y vim curl git
  warn "vim-gtk3 설치 실패 — 기본 vim 설치 완료 (클립보드 미지원 가능)"
fi

VIM_VER=$(vim --version | head -1)
info "설치된 버전: $VIM_VER"

# ════════════════════════════════════════════════════════════
# [2] Node.js 설치 (coc.nvim 요구사항 - Node 16+)
# ════════════════════════════════════════════════════════════
section "[2] Node.js 설치 (coc.nvim 요구사항)"

if ! command -v node &>/dev/null || [[ $(node -e "process.exit(process.version.slice(1).split('.')[0] < 16 ? 1 : 0)" 2>/dev/null; echo $?) -ne 0 ]]; then
  info "Node.js 18 LTS 설치 중..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash - 2>/dev/null || \
    warn "NodeSource 스크립트 실패 — apt nodejs 로 대체 시도"
  apt-get install -y nodejs 2>/dev/null || warn "nodejs 설치 실패 (coc.nvim 비활성화됩니다)"
  success "Node.js $(node --version 2>/dev/null || echo '설치실패') 설치 완료"
else
  success "Node.js $(node --version) 이미 설치됨"
fi

# ════════════════════════════════════════════════════════════
# [3] vim-plug 설치
# ════════════════════════════════════════════════════════════
section "[3] vim-plug 플러그인 매니저 설치"

PLUG_PATH="$REAL_HOME/.vim/autoload/plug.vim"
sudo -u "$REAL_USER" mkdir -p "$(dirname "$PLUG_PATH")"

if [[ ! -f "$PLUG_PATH" ]]; then
  info "vim-plug 다운로드 중..."
  # curl 시 프록시 전달
  PROXY_ARGS=""
  [[ -n "${HTTPS_PROXY:-}" ]] && PROXY_ARGS="--proxy ${HTTPS_PROXY}"
  [[ -n "${HTTP_PROXY:-}"  ]] && PROXY_ARGS="--proxy ${HTTP_PROXY}"

  if sudo -u "$REAL_USER" curl -fLo "$PLUG_PATH" --create-dirs \
       ${PROXY_ARGS} --connect-timeout 30 --retry 3 \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim 2>/dev/null; then
    success "vim-plug 설치 완료 (curl)"
  else
    warn "curl 실패 — git clone 으로 대체 시도"
    TMP_PLUG=$(mktemp -d)
    if sudo -u "$REAL_USER" HOME="$REAL_HOME" \
         git clone --depth=1 https://github.com/junegunn/vim-plug.git "$TMP_PLUG" 2>/dev/null; then
      cp "$TMP_PLUG/plug.vim" "$PLUG_PATH"
      chown "$REAL_USER:$REAL_USER" "$PLUG_PATH"
      rm -rf "$TMP_PLUG"
      success "vim-plug 설치 완료 (git clone)"
    else
      rm -rf "$TMP_PLUG"
      error "vim-plug 다운로드 실패 — 네트워크/프록시 설정을 확인하세요"
    fi
  fi
else
  success "vim-plug 이미 설치됨"
fi

# ════════════════════════════════════════════════════════════
# [4] .vimrc 작성
# ════════════════════════════════════════════════════════════
section "[4] .vimrc 설정"

VIMRC="$REAL_HOME/.vimrc"

# 기존 .vimrc 백업
if [[ -f "$VIMRC" ]]; then
  cp "$VIMRC" "${VIMRC}.bak.$(date +%Y%m%d%H%M%S)"
  info "기존 .vimrc 백업 완료: ${VIMRC}.bak.*"
fi

sudo -u "$REAL_USER" tee "$VIMRC" > /dev/null << 'VIMRCEOF'
" ============================================================
"  .vimrc — 자동 설정 (setup_vim.sh)
" ============================================================

" ── vim-plug 플러그인 ────────────────────────────────────────
call plug#begin('~/.vim/plugged')

" 파일 탐색기
Plug 'preservim/nerdtree'
Plug 'Xuyuanp/nerdtree-git-plugin'       " NERDTree git 상태 표시
Plug 'ryanoasis/vim-devicons'             " 아이콘 (Nerd Font 필요)

" 퍼지 파일 검색
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

" 상태바
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'

" 색상 테마
Plug 'morhetz/gruvbox'
Plug 'joshdick/onedark.vim'

" 문법 강조 (Treesitter 스타일)
Plug 'sheerun/vim-polyglot'

" Git 통합
Plug 'tpope/vim-fugitive'
Plug 'airblade/vim-gitgutter'            " 변경사항 좌측 표시

" 자동 괄호/따옴표 완성
Plug 'jiangmiao/auto-pairs'

" 다중 커서
Plug 'mg979/vim-visual-multi', {'branch': 'master'}

" 주석 토글 (gcc, gc)
Plug 'tpope/vim-commentary'

" 텍스트 오브젝트 확장 (cs"', ds', ys)
Plug 'tpope/vim-surround'

" 들여쓰기 가이드라인
Plug 'Yggdroot/indentLine'

" 공백 강조
Plug 'ntpeters/vim-better-whitespace'

" 코드 자동완성 (LSP) — Node.js 필요
if executable('node')
  Plug 'neoclide/coc.nvim', {'branch': 'release'}
endif

" 터미널 내장
Plug 'voldikss/vim-floaterm'

" 세션 저장/복원
Plug 'tpope/vim-obsession'

call plug#end()

" ── 기본 설정 ───────────────────────────────────────────────
set nocompatible                 " Vi 호환 모드 끄기
filetype plugin indent on        " 파일타입 감지 + 플러그인 + 들여쓰기
syntax on                        " 문법 강조

" 화면
set number                       " 줄번호 표시
set relativenumber               " 상대 줄번호
set cursorline                   " 현재 줄 강조
set showcmd                      " 명령 표시
set showmatch                    " 괄호 쌍 표시
set ruler                        " 커서 위치 표시
set laststatus=2                 " 상태바 항상 표시
set signcolumn=yes               " 좌측 기호 열 (git gutter, coc)
set scrolloff=8                  " 스크롤 여백 (커서 위아래 8줄 유지)
set sidescrolloff=8              " 좌우 스크롤 여백

" 색상 테마
set termguicolors                " 24bit 색상 (터미널이 지원하면)
set background=dark
colorscheme gruvbox

" 탭/들여쓰기
set expandtab                    " 탭 → 스페이스
set tabstop=4                    " 탭 너비
set shiftwidth=4                 " 들여쓰기 너비
set softtabstop=4
set autoindent
set smartindent

" 검색
set hlsearch                     " 검색 결과 강조
set incsearch                    " 점진적 검색
set ignorecase                   " 대소문자 무시
set smartcase                    " 대문자 포함 시 구분

" 성능 / 편의
set hidden                       " 저장 안 한 버퍼 백그라운드 유지
set history=1000
set undofile                     " 영구 undo (재실행 후도 undo 가능)
set undodir=~/.vim/undo
set noswapfile                   " 스왑 파일 생성 안 함
set nobackup
set updatetime=300               " gitgutter / coc 응답 속도 향상
set timeoutlen=500

" 클립보드 (vim-gtk3 필요)
if has('clipboard')
  set clipboard=unnamedplus      " 시스템 클립보드와 통합
endif

" 마우스
set mouse=a                      " 모든 모드에서 마우스 사용

" 인코딩
set encoding=utf-8
set fileencodings=utf-8,cp949,euc-kr

" 줄 바꿈
set wrap
set linebreak                    " 단어 단위로 줄 바꿈
set breakindent                  " 들여쓰기 유지 줄 바꿈

" 와일드 메뉴 (명령 자동완성)
set wildmenu
set wildmode=longest:full,full

" 화면 분할 기본값
set splitright                   " 세로 분할 시 오른쪽에 열기
set splitbelow                   " 가로 분할 시 아래에 열기

" ── 키맵 ────────────────────────────────────────────────────
let mapleader = " "              " Space 를 리더 키로

" NERDTree
nnoremap <leader>e  :NERDTreeToggle<CR>
nnoremap <leader>f  :NERDTreeFind<CR>

" fzf
nnoremap <leader>p  :Files<CR>
nnoremap <leader>b  :Buffers<CR>
nnoremap <leader>/  :Rg<CR>
nnoremap <leader>h  :History<CR>

" 버퍼 이동
nnoremap <Tab>      :bnext<CR>
nnoremap <S-Tab>    :bprevious<CR>
nnoremap <leader>q  :bd<CR>

" 창 이동 (Ctrl+hjkl)
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" 저장
nnoremap <leader>w  :w<CR>
nnoremap <leader>W  :wq<CR>

" 검색 강조 제거
nnoremap <leader><leader> :nohlsearch<CR>

" 줄 이동 (Alt+j/k)
nnoremap <A-j> :m .+1<CR>==
nnoremap <A-k> :m .-2<CR>==
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" 들여쓰기 유지
vnoremap < <gv
vnoremap > >gv

" Floaterm
nnoremap <leader>t  :FloatermNew<CR>
nnoremap <leader>tt :FloatermToggle<CR>
tnoremap <Esc>      <C-\><C-n>

" Git (fugitive)
nnoremap <leader>gs :Git<CR>
nnoremap <leader>gc :Git commit<CR>
nnoremap <leader>gp :Git push<CR>
nnoremap <leader>gl :Git log --oneline<CR>

" ── 플러그인 설정 ────────────────────────────────────────────

" NERDTree
let g:NERDTreeShowHidden      = 1
let g:NERDTreeMinimalUI       = 1
let g:NERDTreeIgnore          = ['\.pyc$', '__pycache__', '\.git$', 'node_modules']
let g:NERDTreeWinSize         = 30
" 마지막 창이 NERDTree 면 자동 닫기
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 &&
  \ exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" vim-airline
let g:airline_powerline_fonts  = 1
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'
let g:airline_theme            = 'gruvbox'

" indentLine
let g:indentLine_char          = '▏'
let g:indentLine_fileTypeExclude = ['help', 'nerdtree', 'startify']

" vim-better-whitespace
let g:better_whitespace_enabled = 1
let g:strip_whitespace_on_save  = 1
let g:strip_whitespace_confirm  = 0

" gitgutter
let g:gitgutter_sign_added    = '▎'
let g:gitgutter_sign_modified = '▎'
let g:gitgutter_sign_removed  = '▁'

" Floaterm
let g:floaterm_width  = 0.85
let g:floaterm_height = 0.85
let g:floaterm_title  = ' Terminal '

" fzf 레이아웃
let g:fzf_layout = { 'window': { 'width': 0.9, 'height': 0.7 } }

" ── coc.nvim 설정 (Node.js 필요) ────────────────────────────
if executable('node')
  " 탭으로 자동완성 선택
  inoremap <silent><expr> <Tab>
    \ coc#pum#visible() ? coc#pum#next(1) :
    \ CheckBackspace() ? "\<Tab>" :
    \ coc#refresh()
  inoremap <expr> <S-Tab> coc#pum#visible() ? coc#pum#prev(1) : "\<S-Tab>"
  inoremap <silent><expr> <CR>
    \ coc#pum#visible() ? coc#pum#confirm() : "\<CR>"

  function! CheckBackspace() abort
    let col = col('.') - 1
    return !col || getline('.')[col - 1] =~# '\s'
  endfunction

  " 정의로 이동
  nmap <silent> gd <Plug>(coc-definition)
  nmap <silent> gy <Plug>(coc-type-definition)
  nmap <silent> gi <Plug>(coc-implementation)
  nmap <silent> gr <Plug>(coc-references)

  " 이름 변경
  nmap <leader>rn <Plug>(coc-rename)

  " 진단 이동
  nmap <silent> [g <Plug>(coc-diagnostic-prev)
  nmap <silent> ]g <Plug>(coc-diagnostic-next)

  " hover 문서 보기
  nnoremap <silent> K :call ShowDocumentation()<CR>
  function! ShowDocumentation()
    if CocAction('hasProvider', 'hover')
      call CocActionAsync('doHover')
    else
      call feedkeys('K', 'in')
    endif
  endfunction

  " 기본 coc 확장 (자동 설치)
  let g:coc_global_extensions = [
    \ 'coc-json',
    \ 'coc-yaml',
    \ 'coc-sh',
    \ 'coc-pyright',
    \ 'coc-tsserver',
    \ 'coc-html',
    \ 'coc-css',
    \ 'coc-markdownlint',
    \ ]
endif

" ── undo 디렉토리 생성 ───────────────────────────────────────
if !isdirectory($HOME . "/.vim/undo")
  call mkdir($HOME . "/.vim/undo", "p")
endif

" ── 파일 타입별 탭 설정 ──────────────────────────────────────
autocmd FileType javascript,typescript,html,css,json,yaml,yml
  \ setlocal tabstop=2 shiftwidth=2 softtabstop=2
autocmd FileType go
  \ setlocal noexpandtab tabstop=4 shiftwidth=4

" ── 마지막 커서 위치 복원 ────────────────────────────────────
autocmd BufReadPost *
  \ if line("'\"") > 1 && line("'\"") <= line("$") |
  \   execute "normal! g'\"" |
  \ endif
VIMRCEOF

chown "$REAL_USER:$REAL_USER" "$VIMRC"
success ".vimrc 작성 완료"

# ════════════════════════════════════════════════════════════
# [5] 플러그인 자동 설치
# ════════════════════════════════════════════════════════════
section "[5] vim-plug 플러그인 설치 (git clone 직접 방식)"

PLUG_DIR="$REAL_HOME/.vim/plugged"
sudo -u "$REAL_USER" mkdir -p "$PLUG_DIR"

# git clone 헬퍼 (프록시 환경 자동 상속)
clone_plugin() {
  local repo="$1" dir="$2"
  local dest="$PLUG_DIR/$dir"
  if [[ -d "$dest/.git" ]]; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
      git -C "$dest" pull --ff-only --quiet 2>/dev/null \
      && echo "  [업데이트] $dir" || echo "  [유지] $dir (pull 실패)"
  else
    rm -rf "$dest"
    if sudo -u "$REAL_USER" HOME="$REAL_HOME" \
         git clone --depth=1 "https://github.com/${repo}.git" "$dest" --quiet 2>/dev/null; then
      echo "  [설치] $dir"
    else
      warn "clone 실패: $repo (네트워크/프록시 확인)"
    fi
  fi
}

clone_plugin "preservim/nerdtree"                 "nerdtree"
clone_plugin "Xuyuanp/nerdtree-git-plugin"        "nerdtree-git-plugin"
clone_plugin "ryanoasis/vim-devicons"             "vim-devicons"
clone_plugin "junegunn/fzf"                       "fzf"
clone_plugin "junegunn/fzf.vim"                   "fzf.vim"
clone_plugin "vim-airline/vim-airline"            "vim-airline"
clone_plugin "vim-airline/vim-airline-themes"     "vim-airline-themes"
clone_plugin "morhetz/gruvbox"                    "gruvbox"
clone_plugin "joshdick/onedark.vim"               "onedark.vim"
clone_plugin "sheerun/vim-polyglot"               "vim-polyglot"
clone_plugin "tpope/vim-fugitive"                 "vim-fugitive"
clone_plugin "airblade/vim-gitgutter"             "vim-gitgutter"
clone_plugin "jiangmiao/auto-pairs"               "auto-pairs"
clone_plugin "mg979/vim-visual-multi"             "vim-visual-multi"
clone_plugin "tpope/vim-commentary"               "vim-commentary"
clone_plugin "tpope/vim-surround"                 "vim-surround"
clone_plugin "Yggdroot/indentLine"                "indentLine"
clone_plugin "ntpeters/vim-better-whitespace"     "vim-better-whitespace"
clone_plugin "voldikss/vim-floaterm"              "vim-floaterm"
clone_plugin "tpope/vim-obsession"                "vim-obsession"

# coc.nvim — release 브랜치
if command -v node &>/dev/null; then
  COC_DIR="$PLUG_DIR/coc.nvim"
  if [[ -d "$COC_DIR/.git" ]]; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
      git -C "$COC_DIR" pull --ff-only --quiet 2>/dev/null && echo "  [업데이트] coc.nvim" || true
  else
    rm -rf "$COC_DIR"
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
      git clone --depth=1 -b release https://github.com/neoclide/coc.nvim.git "$COC_DIR" --quiet 2>/dev/null \
      && echo "  [설치] coc.nvim" || warn "coc.nvim clone 실패"
  fi
fi

# fzf 바이너리 설치 (go 빌드 대신 pre-built 바이너리)
FZF_INSTALL="$PLUG_DIR/fzf/install"
if [[ -f "$FZF_INSTALL" ]]; then
  sudo -u "$REAL_USER" HOME="$REAL_HOME" \
    bash "$FZF_INSTALL" --bin 2>/dev/null \
    && echo "  [설치] fzf 바이너리" || warn "fzf 바이너리 설치 실패 (수동: ~/.vim/plugged/fzf/install --bin)"
fi

# vim-plug 상태 파일 생성 (vim이 이미 설치된 것으로 인식하게)
sudo -u "$REAL_USER" HOME="$REAL_HOME" \
  vim -u "$VIMRC" -c 'PlugStatus' -c 'sleep 1' -c 'qa!' 2>/dev/null || true

success "플러그인 설치 완료"

# ════════════════════════════════════════════════════════════
# [6] coc-settings.json 작성
# ════════════════════════════════════════════════════════════
section "[6] coc-settings.json 작성"

COC_SETTINGS="$REAL_HOME/.vim/coc-settings.json"
sudo -u "$REAL_USER" mkdir -p "$(dirname "$COC_SETTINGS")"
sudo -u "$REAL_USER" tee "$COC_SETTINGS" > /dev/null << 'COCEOF'
{
  "suggest.noselect": true,
  "suggest.enablePreview": true,
  "suggest.floatConfig": { "border": true },
  "diagnostic.enableSign": true,
  "diagnostic.errorSign": "✘",
  "diagnostic.warningSign": "▲",
  "diagnostic.infoSign": "ℹ",
  "inlayHint.enable": false,
  "python.analysis.typeCheckingMode": "basic",
  "python.defaultInterpreter": "/usr/bin/python3",
  "json.schemas": [],
  "yaml.schemas": {}
}
COCEOF
success "coc-settings.json 작성 완료"

# ════════════════════════════════════════════════════════════
# [7] Nerd Font 설치 (airline 아이콘 지원)
# ════════════════════════════════════════════════════════════
section "[7] Nerd Font 설치 (JetBrainsMono Nerd Font)"

FONT_DIR="$REAL_HOME/.local/share/fonts"
FONT_NAME="JetBrainsMonoNerdFont-Regular.ttf"
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"

sudo -u "$REAL_USER" mkdir -p "$FONT_DIR"

if [[ ! -f "$FONT_DIR/$FONT_NAME" ]]; then
  TMP_DIR=$(mktemp -d)
  if curl -fL --connect-timeout 15 "$FONT_URL" -o "$TMP_DIR/JetBrainsMono.zip" 2>/dev/null; then
    unzip -q "$TMP_DIR/JetBrainsMono.zip" -d "$TMP_DIR/fonts" 2>/dev/null || true
    find "$TMP_DIR/fonts" -name "*.ttf" ! -name "*Windows*" \
      -exec cp {} "$FONT_DIR/" \; 2>/dev/null || true
    fc-cache -fv "$FONT_DIR" &>/dev/null
    success "JetBrainsMono Nerd Font 설치 완료"
  else
    warn "폰트 다운로드 실패 (네트워크 문제 또는 프록시 필요) — 수동 설치 필요"
    info "  수동 설치: https://www.nerdfonts.com/font-downloads"
  fi
  rm -rf "$TMP_DIR"
else
  success "JetBrainsMono Nerd Font 이미 설치됨"
fi

# ════════════════════════════════════════════════════════════
# 완료
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  Vim 설정 자동화 완료!                           ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
printf "  %-5s %-25s %s\n" "[1]"  "vim-gtk3"              "클립보드 지원 vim"
printf "  %-5s %-25s %s\n" "[2]"  "Node.js"               "coc.nvim LSP 요구사항"
printf "  %-5s %-25s %s\n" "[3]"  "vim-plug"              "플러그인 매니저"
printf "  %-5s %-25s %s\n" "[4]"  ".vimrc"                "NERDTree/fzf/airline/coc 포함"
printf "  %-5s %-25s %s\n" "[5]"  "PlugInstall"           "플러그인 자동 설치"
printf "  %-5s %-25s %s\n" "[6]"  "coc-settings.json"     "LSP 설정 (Python/TS/YAML 등)"
printf "  %-5s %-25s %s\n" "[7]"  "JetBrainsMono Nerd"    "아이콘 폰트"
echo ""
echo "  주요 키맵 (Space = 리더키):"
printf "  %-18s %s\n" "<Space>e"  "NERDTree 열기/닫기"
printf "  %-18s %s\n" "<Space>p"  "파일 퍼지 검색 (fzf)"
printf "  %-18s %s\n" "<Space>/"  "내용 검색 (ripgrep)"
printf "  %-18s %s\n" "<Space>t"  "플로팅 터미널"
printf "  %-18s %s\n" "<Space>gs" "git status"
printf "  %-18s %s\n" "gd"        "정의로 이동 (coc)"
printf "  %-18s %s\n" "K"         "hover 문서 (coc)"
printf "  %-18s %s\n" "Tab/Esc"   "자동완성 선택/취소"
echo ""
warn "터미널 폰트를 'JetBrainsMono Nerd Font' 로 변경하면 아이콘이 표시됩니다."
warn "vim 최초 실행 시 :PlugInstall 이 자동 완료되지 않으면 수동 실행하세요."
echo ""
