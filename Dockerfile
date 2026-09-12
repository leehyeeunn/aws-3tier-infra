# 1. 가볍고 취약점이 적은 slim 베이스 이미지 채택 (FinOps/보안)
FROM python:3.11-slim

# 2. 파이썬 표준 입출력 버퍼링 비활성화 (컨테이너 로그 유실 방지)
ENV PYTHONUNBUFFERED=1

# 3. 작업 디렉터리 지정
WORKDIR /app

# 4. 레이어 캐싱 최적화 (의존성 파일 먼저 복사 및 설치)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 5. 소스 코드 복사
COPY . .

# 6. 서비스 포트 8000 명시
EXPOSE 8000

# 7. 외부 인입 허용을 위한 0.0.0.0 바인딩
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]