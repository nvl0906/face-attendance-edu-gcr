FROM python:3.10-slim

ENV PYTHONUNBUFFERED True

COPY face_attendance_edu/service/requirements.txt ./

RUN pip install -r requirements.txt

ENV APP_HOME /app
WORKDIR $APP_HOME
COPY face_attendance_edu $APP_HOME/face_attendance_edu

CMD ["uvicorn", "face_attendance_edu.service.main:app", "--host", "0.0.0.0", "--port", "8080"]
