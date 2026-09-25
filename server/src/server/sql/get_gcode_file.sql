select
  bytes
from
  gcode_files
where
  id = $1;
