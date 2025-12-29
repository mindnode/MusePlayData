#!/bin/bash

# MIDI 파일 스캔 및 JSON 변환 스크립트
# 실행 위치 하위의 new 디렉토리에서 MIDI 파일을 스캔하여 JSON으로 변환

set -e  # 오류 발생 시 즉시 중단

# ============================================================================
# 색상 정의
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# ============================================================================
# 전역 변수
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_DIR="${SCRIPT_DIR}/new"
MIDI_DIR="${SCRIPT_DIR}/midi"
OUTPUT_FILE="${SCRIPT_DIR}/museplay.json"
LOG_FILE="${SCRIPT_DIR}/history.log"

SUCCESS_COUNT=0
FAIL_COUNT=0
PROCESSED_FILES=()
FAILED_FILES=()
BASE_NAME=""

# ============================================================================
# 로깅 함수
# ============================================================================
log_info() {
    local message="$1"
    local colored_message="${BLUE}[정보]${NC} ${message}"
    local plain_message="[정보] ${message}"
    echo -e "$colored_message"
    echo "$plain_message" >> "${LOG_FILE}"
}

log_success() {
    local message="$1"
    local colored_message="${GREEN}[성공]${NC} ${message}"
    local plain_message="[성공] ${message}"
    echo -e "$colored_message"
    echo "$plain_message" >> "${LOG_FILE}"
}

log_warn() {
    local message="$1"
    local colored_message="${YELLOW}[경고]${NC} ${message}"
    local plain_message="[경고] ${message}"
    echo -e "$colored_message"
    echo "$plain_message" >> "${LOG_FILE}"
}

log_error() {
    local message="$1"
    local colored_message="${RED}[오류]${NC} ${message}"
    local plain_message="[오류] ${message}"
    echo -e "$colored_message"
    echo "$plain_message" >> "${LOG_FILE}"
}

log_debug() {
    local message="$1"
    local colored_message="${GRAY}[디버그]${NC} ${message}"
    local plain_message="[디버그] ${message}"
    echo -e "$colored_message"
    echo "$plain_message" >> "${LOG_FILE}"
}

# ============================================================================
# 텍스트 정규화 함수
# ============================================================================
normalize_text() {
    local text="$1"
    # _ → 공백
    text="${text//_/ }"
    # 특수기호를 공백으로 변환 (알파벳, 숫자, 한글, 작은따옴표는 유지)
    text=$(echo "$text" | sed "s/[^a-zA-Z0-9가-힣 ']/ /g")
    # 연속 공백 → 단일 공백
    text=$(echo "$text" | sed 's/  */ /g')
    # 앞뒤 공백 제거
    text=$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$text"
}

# ============================================================================
# JSON 이스케이프 함수
# ============================================================================
json_escape() {
    local text="$1"
    # 백슬래시 이스케이프
    text="${text//\\/\\\\}"
    # 따옴표 이스케이프
    text="${text//\"/\\\"}"
    # 개행 문자 이스케이프
    text="${text//$'\n'/\\n}"
    # 캐리지 리턴 이스케이프
    text="${text//$'\r'/\\r}"
    # 탭 문자 이스케이프
    text="${text//$'\t'/\\t}"
    echo "$text"
}

# ============================================================================
# 파일명 파싱 함수
# ============================================================================
parse_filename() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    
    # 확장자 확인 (.mid 또는 .midi로 끝나는지 확인)
    if [[ ! "$filename" =~ \.(mid|midi)$ ]]; then
        return 1
    fi
    
    # 확장자 제거 (.mid 또는 .midi만 제거)
    # 다중 확장자(예: .mscz.midi)의 경우 .midi만 제거
    local name_without_ext="${filename}"
    if [[ "$name_without_ext" =~ \.midi$ ]]; then
        name_without_ext="${name_without_ext%.midi}"
    elif [[ "$name_without_ext" =~ \.mid$ ]]; then
        name_without_ext="${name_without_ext%.mid}"
    fi
    
    # 하이픈으로 분리 (엄격한 규칙: <난이도>-<곡 제목>-<아티스트명>)
    IFS='-' read -ra PARTS <<< "$name_without_ext"
    
    if [ ${#PARTS[@]} -ne 3 ]; then
        return 1
    fi
    
    local difficulty="${PARTS[0]}"
    local title="${PARTS[1]}"
    local artist="${PARTS[2]}"
    
    # 아티스트명에서 남은 확장자 제거 (예: .mscz)
    # 알려진 확장자 패턴 제거
    artist="${artist%.mscz}"
    artist="${artist%.mscx}"
    artist="${artist%.mxl}"
    artist="${artist%.musicxml}"
    
    # 난이도 검증 (1-5만 허용)
    if ! [[ "$difficulty" =~ ^[1-5]$ ]]; then
        return 1
    fi
    
    # 빈 필드 검증
    if [ -z "$title" ] || [ -z "$artist" ]; then
        return 1
    fi
    
    # 텍스트 정규화
    title=$(normalize_text "$title")
    artist=$(normalize_text "$artist")
    
    # 정규화 후 다시 빈 필드 검증
    if [ -z "$title" ] || [ -z "$artist" ]; then
        return 1
    fi
    
    # 난이도 매핑
    local difficulty_map=("" "초급" "초급" "중급" "고급" "최상")
    local difficulty_text="${difficulty_map[$difficulty]}"
    
    # 결과 반환 (전역 변수 사용)
    PARSED_DIFFICULTY="$difficulty_text"
    PARSED_TITLE="$title"
    PARSED_ARTIST="$artist"
    
    return 0
}

# ============================================================================
# 파일 정보 추출 함수
# ============================================================================
get_file_info() {
    local filepath="$1"
    
    # 파일 크기 (바이트)
    local file_size=$(stat -f%z "$filepath" 2>/dev/null || echo "0")
    
    # 파일 생성일 (YYYY-MM-DD 형식)
    # macOS에서는 stat -f%B로 생성 시간(Unix 타임스탬프)을 가져온 후 date로 변환
    local birth_time=$(stat -f%B "$filepath" 2>/dev/null)
    local file_date=""
    
    if [ -n "$birth_time" ] && [ "$birth_time" != "0" ]; then
        file_date=$(date -r "$birth_time" +"%Y-%m-%d" 2>/dev/null)
    fi
    
    # 대체 방법: 수정 시간 사용
    if [ -z "$file_date" ]; then
        local mod_time=$(stat -f%m "$filepath" 2>/dev/null)
        if [ -n "$mod_time" ] && [ "$mod_time" != "0" ]; then
            file_date=$(date -r "$mod_time" +"%Y-%m-%d" 2>/dev/null)
        fi
    fi
    
    # 최종 대체: 현재 날짜 사용
    if [ -z "$file_date" ]; then
        file_date=$(date +"%Y-%m-%d")
    fi
    
    FILE_SIZE="$file_size"
    FILE_DATE="$file_date"
}

# ============================================================================
# 파일 목록 표시 함수
# ============================================================================
display_file_list() {
    local files=("$@")
    
    echo ""
    log_info "발견된 MIDI 파일 목록:"
    echo ""
    
    # 테이블 헤더
    printf "%-50s %-12s %-12s %-15s %-30s %-20s\n" \
        "Filename" "Size (bytes)" "Date" "Difficulty" "Title" "Artist"
    echo "-----------------------------------------------------------------------------------------------------------------------------------------------"
    
    local preview_data=()
    
    for filepath in "${files[@]}"; do
        local filename=$(basename "$filepath")
        
        # 파싱 시도
        if parse_filename "$filepath"; then
            get_file_info "$filepath"
            
            printf "%-50s %-12s %-12s %-15s %-30s %-20s\n" \
                "$filename" \
                "$FILE_SIZE" \
                "$FILE_DATE" \
                "$PARSED_DIFFICULTY" \
                "$PARSED_TITLE" \
                "$PARSED_ARTIST"
            
            preview_data+=("${filename}|${FILE_SIZE}|${FILE_DATE}|${PARSED_DIFFICULTY}|${PARSED_TITLE}|${PARSED_ARTIST}")
        else
            printf "%-50s %-12s %-12s %-15s %-30s %-20s\n" \
                "$filename" \
                "-" \
                "-" \
                "${RED}파싱 실패${NC}" \
                "-" \
                "-"
        fi
    done
    
    echo ""
    log_info "총 ${#files[@]}개의 파일이 발견되었습니다."
}

# ============================================================================
# 중복 검사 함수
# ============================================================================
check_duplicates() {
    local seen=()
    local duplicates=()
    
    for filepath in "${PROCESSED_FILES[@]}"; do
        if parse_filename "$filepath"; then
            local key="${PARSED_TITLE}|${PARSED_ARTIST}"
            local found=false
            local existing_file=""
            
            # 기존 키 검색
            for item in "${seen[@]}"; do
                if [[ "$item" =~ ^${key}\| ]]; then
                    found=true
                    existing_file="${item#*|}"
                    break
                fi
            done
            
            if [ "$found" = true ]; then
                duplicates+=("$filepath")
                duplicates+=("$existing_file")
            else
                seen+=("${key}|${filepath}")
            fi
        fi
    done
    
    if [ ${#duplicates[@]} -gt 0 ]; then
        log_warn "중복된 곡이 발견되었습니다:"
        for dup in "${duplicates[@]}"; do
            local filename=$(basename "$dup")
            log_warn "  - ${filename}"
        done
        log_info "중복 파일은 자동으로 스킵하고 계속 진행합니다."
    fi
}

# ============================================================================
# JSON 생성 함수
# ============================================================================
create_json() {
    log_info "JSON 파일 생성 중..."
    
    # 파일 생성 날짜와 시간
    local creation_date=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 처리된 파일 수 계산
    local file_count=0
    for filepath in "${PROCESSED_FILES[@]}"; do
        if parse_filename "$filepath"; then
            file_count=$((file_count + 1))
        fi
    done
    
    # JSON 시작 (메타데이터 포함)
    local json_data="{"
    json_data+="\n  \"created_date\": \"${creation_date}\","
    json_data+="\n  \"basedir\": \"midi/\","
    json_data+="\n  \"file_count\": ${file_count},"
    json_data+="\n  \"files\": ["
    
    local first=true
    
    # 파일 수정일 기준 최신순으로 정렬하기 위해 임시 파일 사용
    local temp_sort_file=$(mktemp)
    
    for filepath in "${PROCESSED_FILES[@]}"; do
        # 파일 수정일 (Unix 타임스탬프)
        local mod_time=$(stat -f%m "$filepath" 2>/dev/null || echo "0")
        # 정렬 키: 수정일(내림차순)|파일경로
        echo "${mod_time}|${filepath}" >> "$temp_sort_file"
    done
    
    # 정렬 (수정일 기준 내림차순 - 최신순)
    local -a sorted_files
    while IFS='|' read -r mod_time filepath; do
        sorted_files+=("$filepath")
    done < <(sort -t'|' -k1,1rn "$temp_sort_file")
    
    rm -f "$temp_sort_file"
    
    # JSON 생성
    for filepath in "${sorted_files[@]}"; do
        if parse_filename "$filepath"; then
            get_file_info "$filepath"
            local filename=$(basename "$filepath")
            
            if [ "$first" = true ]; then
                first=false
            else
                json_data+=","
            fi
            
            # JSON 이스케이프 처리
            local escaped_filename=$(json_escape "$filename")
            local escaped_title=$(json_escape "$PARSED_TITLE")
            local escaped_artist=$(json_escape "$PARSED_ARTIST")
            local escaped_difficulty=$(json_escape "$PARSED_DIFFICULTY")
            
            json_data+="\n    {"
            json_data+="\n      \"filename\": \"${escaped_filename}\","
            json_data+="\n      \"file_size\": ${FILE_SIZE},"
            json_data+="\n      \"title\": \"${escaped_title}\","
            json_data+="\n      \"artist\": \"${escaped_artist}\","
            json_data+="\n      \"difficulty\": \"${escaped_difficulty}\","
            json_data+="\n      \"youtube\": \"\""
            json_data+="\n    }"
        fi
    done
    
    json_data+="\n  ]"
    json_data+="\n}"
    
    # JSON 파일 저장
    echo -e "$json_data" > "${OUTPUT_FILE}"
    
    log_success "JSON 파일 생성 완료: ${OUTPUT_FILE}"
}

# ============================================================================
# 리포트 생성 함수
# ============================================================================
generate_report() {
    echo ""
    log_info "=== 처리 결과 리포트 ==="
    echo ""
    
    # 요약
    log_success "성공: ${SUCCESS_COUNT}개 파일"
    if [ $FAIL_COUNT -gt 0 ]; then
        log_error "실패: ${FAIL_COUNT}개 파일"
    fi
    echo ""
    
    # 상세 리스트
    if [ ${#PROCESSED_FILES[@]} -gt 0 ]; then
        log_info "성공한 파일 목록:"
        for filepath in "${PROCESSED_FILES[@]}"; do
            local filename=$(basename "$filepath")
            log_success "  ✓ ${filename}"
        done
        echo ""
    fi
    
    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        log_error "실패한 파일 목록:"
        for filepath in "${FAILED_FILES[@]}"; do
            local filename=$(basename "$filepath")
            log_error "  ✗ ${filename}"
        done
        echo ""
    fi
}

# ============================================================================
# 메인 함수
# ============================================================================
main() {
    log_info "MIDI 파일 스캔 및 JSON 변환 스크립트 시작"
    log_info "작업 디렉토리: ${SCRIPT_DIR}"
    log_info "로그 파일: ${LOG_FILE}"
    echo ""
    
    # new와 midi 디렉토리 확인
    if [ ! -d "$NEW_DIR" ]; then
        log_warn "new 디렉토리를 찾을 수 없습니다: ${NEW_DIR}"
    fi
    
    if [ ! -d "$MIDI_DIR" ]; then
        log_warn "midi 디렉토리를 찾을 수 없습니다: ${MIDI_DIR}"
    fi
    
    if [ ! -d "$NEW_DIR" ] && [ ! -d "$MIDI_DIR" ]; then
        log_error "new와 midi 디렉토리가 모두 없습니다."
        exit 1
    fi
    
    # new 폴더의 MIDI 파일을 midi 디렉토리로 이동
    if [ -d "$NEW_DIR" ]; then
        log_info "new 폴더의 MIDI 파일을 midi 디렉토리로 이동 중..."
        
        # midi 디렉토리가 없으면 생성
        if [ ! -d "$MIDI_DIR" ]; then
            mkdir -p "$MIDI_DIR"
            log_success "midi 디렉토리 생성 완료: ${MIDI_DIR}"
        fi
        
        # new 폴더의 MIDI 파일 찾기
        local new_files=()
        while IFS= read -r -d '' file; do
            new_files+=("$file")
        done < <(find "$NEW_DIR" -maxdepth 1 -type f \( -name "*.mid" -o -name "*.midi" \) -print0 2>/dev/null)
        
        if [ ${#new_files[@]} -gt 0 ]; then
            for filepath in "${new_files[@]}"; do
                local filename=$(basename "$filepath")
                local dest_path="${MIDI_DIR}/${filename}"
                mv "$filepath" "$dest_path"
                log_success "파일 이동: ${filename}"
            done
            log_success "${#new_files[@]}개의 파일을 midi 디렉토리로 이동 완료"
        else
            log_info "new 폴더에 MIDI 파일이 없습니다."
        fi
    fi
    
    # midi 디렉토리의 MIDI 파일 스캔
    log_info "midi 디렉토리에서 MIDI 파일 스캔 중..."
    local midi_files=()
    
    while IFS= read -r -d '' file; do
        midi_files+=("$file")
    done < <(find "$MIDI_DIR" -maxdepth 1 -type f \( -name "*.mid" -o -name "*.midi" \) -print0 2>/dev/null)
    
    if [ ${#midi_files[@]} -eq 0 ]; then
        log_warn "MIDI 파일을 찾을 수 없습니다."
        exit 0
    fi
    
    log_success "${#midi_files[@]}개의 MIDI 파일 발견"
    
    # 파일 목록 표시
    display_file_list "${midi_files[@]}"
    
    # 사용자 확인
    echo ""

    
    # 기존 JSON 파일 확인
    if [ -f "$OUTPUT_FILE" ]; then
        log_warn "기존 JSON 파일이 존재합니다: ${OUTPUT_FILE}"
        read -p "덮어쓰시겠습니까? (y/n): " REPLY
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "사용자가 취소했습니다."
            exit 0
        fi
        
        # 백업 생성
        local backup_file="${OUTPUT_FILE}.bak"
        cp "$OUTPUT_FILE" "$backup_file"
        log_success "백업 파일 생성: ${backup_file}"
    fi
    
    # 파일 처리
    log_info "파일 처리 시작..."
    local total=${#midi_files[@]}
    local current=0
    
    for filepath in "${midi_files[@]}"; do
        current=$((current + 1))
        local filename=$(basename "$filepath")
        log_info "처리 중: ${current}/${total} - ${filename}"
        
        if parse_filename "$filepath"; then
            PROCESSED_FILES+=("$filepath")
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            log_success "파싱 성공: ${filename}"
        else
            FAILED_FILES+=("$filepath")
            FAIL_COUNT=$((FAIL_COUNT + 1))
            log_warn "파싱 실패: ${filename} (파일명 규칙 불일치)"
        fi
    done
    
    if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
        log_error "처리 가능한 파일이 없습니다."
        exit 1
    fi
    
    # 중복 검사
    check_duplicates
    
    # JSON 생성
    create_json
    
    # 리포트 생성
    generate_report
    
    # 새로운 new 폴더 생성
    local new_folder="${SCRIPT_DIR}/new"
    mkdir -p "$new_folder"
    log_success "새로운 new 폴더 생성 완료: ${new_folder}"
    
    log_success "모든 작업이 완료되었습니다!"
}

# ============================================================================
# 스크립트 실행
# ============================================================================
main "$@"

