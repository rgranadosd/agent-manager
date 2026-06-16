// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package dbmigrations

import (
	"gorm.io/gorm"
)

var migration024 = migration{
	ID: 24,
	Migrate: func(db *gorm.DB) error {
		addOAuthConfig := `
		ALTER TABLE agent_configs
			ADD COLUMN IF NOT EXISTS enable_oauth_security    BOOLEAN NOT NULL DEFAULT false,
			ADD COLUMN IF NOT EXISTS oauth_issuers            JSONB   NOT NULL DEFAULT '[]',
			ADD COLUMN IF NOT EXISTS oauth_audiences          JSONB   NOT NULL DEFAULT '[]',
			ADD COLUMN IF NOT EXISTS oauth_required_scopes    JSONB   NOT NULL DEFAULT '[]',
			ADD COLUMN IF NOT EXISTS oauth_required_claims     JSONB   NOT NULL DEFAULT '{}',
			ADD COLUMN IF NOT EXISTS oauth_header_name        TEXT    NOT NULL DEFAULT 'Authorization',
			ADD COLUMN IF NOT EXISTS oauth_auth_header_prefix TEXT    NOT NULL DEFAULT 'Bearer';
		`
		return db.Exec(addOAuthConfig).Error
	},
}
