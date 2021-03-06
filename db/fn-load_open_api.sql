set role dba;
DROP FUNCTION IF EXISTS load_open_api;
CREATE OR REPLACE FUNCTION load_open_api (
  custom_release text default null
  )
RETURNS text AS $$
from string import Template
import json
import time
import datetime
from urllib.request import urlopen, urlretrieve
from snoopUtils import determine_bucket_job, fetch_swagger
K8S_REPO_URL = "https://raw.githubusercontent.com/kubernetes/kubernetes/"
OPEN_API_PATH = "/api/openapi-spec/swagger.json"

release_dates = {
  "v1.0.0": "2015-07-10",
  "v1.1.0": "2015-11-09",
  "v1.2.0": "2016-03-16",
  "v1.3.0": "2016-07-01",
  "v1.4.0": "2016-09-26",
  "v1.5.0": "2016-12-12",
  "v1.6.0": "2017-03-28",
  "v1.7.0": "2017-06-30",
  "v1.8.0": "2017-08-28",
  "v1.9.0": "2017-12-15",
  "v1.10.0": "2018-03-26",
  "v1.11.0":  "2018-06-27",
  "v1.12.0": "2018-09-27",
  "v1.13.0": "2018-12-03" ,
  "v1.14.0": "2019-03-25",
  "v1.15.0": "2019-06-19",
  "v1.16.0": "2019-09-18",
  "v1.17.0": "2019-12-07",
  "v1.18.0": "2020-03-25"
}
if custom_release is not None:
  release = custom_release
  open_api_url = K8S_REPO_URL + release + OPEN_API_PATH
  open_api = json.loads(urlopen(open_api_url).read().decode('utf-8')) # may change this to ascii
  rd = release_dates[release]
  release_date = time.mktime(datetime.datetime.strptime(rd, "%Y-%m-%d").timetuple())
else:
  bucket, job = determine_bucket_job()
  swagger, metadata, commit_hash = fetch_swagger(bucket, job)
  open_api = swagger
  open_api_url = K8S_REPO_URL + commit_hash + OPEN_API_PATH
  release_date = int(metadata['timestamp'])
  release = metadata["version"].split('-')[0].replace('v','')

sql = Template("""
   WITH open AS (
     SELECT '${open_api}'::jsonb as api_data)
       INSERT INTO open_api(
         release,
         release_date,
         endpoint,
         level,
         category,
         path,
         k8s_group,
         k8s_version,
         k8s_kind,
         k8s_action,
         deprecated,
         description,
         spec
       )
   SELECT
     trim(leading 'v' from '${release}') as release,
     to_timestamp(${release_date}) as release_date,
     (d.value ->> 'operationId'::text) as endpoint,
     CASE
       WHEN paths.key ~~ '%alpha%' THEN 'alpha'
       WHEN paths.key ~~ '%beta%' THEN 'beta'
       ELSE 'stable'
     END AS level,
     split_part((cat_tag.value ->> 0), '_'::text, 1) AS category,
     paths.key AS path,
     ((d.value -> 'x-kubernetes-group-version-kind'::text) ->> 'group'::text) AS k8s_group,
     ((d.value -> 'x-kubernetes-group-version-kind'::text) ->> 'version'::text) AS k8s_version,
     ((d.value -> 'x-kubernetes-group-version-kind'::text) ->> 'kind'::text) AS k8s_kind,
     (d.value ->> 'x-kubernetes-action'::text) AS k8s_action,
     CASE
       WHEN (lower((d.value ->> 'description'::text)) ~~ '%deprecated%'::text) THEN true
       ELSE false
     END AS deprecated,
     (d.value ->> 'description'::text) AS description,
     '${open_api_url}' as spec
     FROM
         open
          , jsonb_each((open.api_data -> 'paths'::text)) paths(key, value)
          , jsonb_each(paths.value) d(key, value)
          , jsonb_array_elements((d.value -> 'tags'::text)) cat_tag(value)
    ORDER BY paths.key;
              """).substitute(release = release,
                              release_date = release_date,
                              open_api = json.dumps(open_api).replace("'","''"),
                              open_api_url = open_api_url)
try:
  plpy.execute((sql))
  return "{} open api is loaded".format(custom_release if custom_release else "current")
except:
  return "an error occurred"
$$ LANGUAGE plpython3u ;
reset role;
