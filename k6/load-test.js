import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const TARGET_HOST = __ENV.TARGET_HOST || 'http://aduke.local';

const jobsCreated = new Counter('jobs_created');
const jobsFailed = new Counter('jobs_failed');

export const options = {
  stages: [
    { duration: '2m', target: 50 },
    { duration: '5m', target: 50 },
    { duration: '2m', target: 5 },
    { duration: '5m', target: 5 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
  },
};

export default function () {
  const res = http.post(`${TARGET_HOST}/jobs`, null, {
    headers: { 'Content-Type': 'application/json' },
  });

  const ok = check(res, {
    'status is 202': (r) => r.status === 202,
  });

  if (ok) {
    jobsCreated.add(1);
  } else {
    jobsFailed.add(1);
  }

  sleep(1);
}