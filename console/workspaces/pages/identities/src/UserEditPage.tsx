/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  Divider,
  Stack,
  TextField,
  Typography,
} from "@wso2/oxygen-ui";
import { generatePath, useNavigate, useParams } from "react-router-dom";
import {
  useGetUser,
  useGetUserGroups,
  useAllGroups,
  useAddGroupMembers,
  useRemoveGroupMembers,
} from "@agent-management-platform/api-client";
import { PageLayout } from "@agent-management-platform/views";
import { absoluteRouteMap, type ThunderGroup } from "@agent-management-platform/types";

export const UserEditPage: React.FC = () => {
  const { orgId, userId } = useParams<{ orgId: string; userId: string }>();
  const navigate = useNavigate();

  const { data: user, isLoading: isLoadingUser } = useGetUser({
    orgName: orgId,
    userId: userId ?? "",
  });

  const { data: userGroupsData, isLoading: isLoadingUserGroups } = useGetUserGroups({
    orgName: orgId,
    userId: userId ?? "",
  });

  const { data: allGroupsData, isLoading: isLoadingAllGroups } = useAllGroups({ orgName: orgId });

  const { mutateAsync: addMembers } = useAddGroupMembers();
  const { mutateAsync: removeMembers } = useRemoveGroupMembers();

  const allGroups: ThunderGroup[] = useMemo(() => allGroupsData?.groups ?? [], [allGroupsData]);
  const initialGroups: ThunderGroup[] = useMemo(
    () => userGroupsData?.groups ?? [],
    [userGroupsData],
  );

  const [selectedGroups, setSelectedGroups] = useState<ThunderGroup[]>([]);
  const [isSaving, setIsSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | undefined>();
  const [saveSuccess, setSaveSuccess] = useState(false);
  const hasEdited = useRef(false);

  useEffect(() => {
    if (!hasEdited.current) {
      setSelectedGroups(initialGroups);
    }
  }, [initialGroups]);

  const usersPath = orgId
    ? generatePath(
        (absoluteRouteMap.children.org.children as unknown as {
          identities: { children: { users: { path: string } } };
        }).identities.children.users.path,
        { orgId },
      )
    : "#";

  const username = String(user?.attributes?.["username"] ?? userId ?? "");

  const handleSave = async () => {
    if (!orgId || !userId) return;
    setSaveError(undefined);
    setSaveSuccess(false);
    setIsSaving(true);
    try {
      const currentGroupIds = new Set(initialGroups.map((g) => g.id));
      const nextGroupIds = new Set(selectedGroups.map((g) => g.id));

      const toAdd = selectedGroups.filter((g) => !currentGroupIds.has(g.id));
      const toRemove = initialGroups.filter((g) => !nextGroupIds.has(g.id));

      for (const g of toAdd) {
        await addMembers({
          params: { orgName: orgId, groupId: g.id },
          body: { userIds: [userId] },
        });
      }
      for (const g of toRemove) {
        await removeMembers({
          params: { orgName: orgId, groupId: g.id },
          body: { userIds: [userId] },
        });
      }

      setSaveSuccess(true);
      hasEdited.current = false;
    } catch {
      setSaveError("Failed to update group memberships. Please try again.");
    } finally {
      setIsSaving(false);
    }
  };

  const isLoading = isLoadingUser || isLoadingUserGroups || isLoadingAllGroups;

  if (isLoading) {
    return (
      <PageLayout title="Edit User" disableIcon>
        <Box display="flex" justifyContent="center" mt={4}>
          <CircularProgress />
        </Box>
      </PageLayout>
    );
  }

  return (
    <PageLayout
      title={`Edit User: ${username}`}
      backHref={usersPath}
      backLabel="Back to Users"
      disableIcon
    >
      <Stack spacing={3} sx={{ maxWidth: 700 }}>
        {saveError != null && <Alert severity="error">{saveError}</Alert>}
        {saveSuccess && <Alert severity="success">User updated successfully.</Alert>}

        <Box>
          <Typography variant="subtitle1" fontWeight={600} mb={1}>
            Group Memberships
          </Typography>
          <Typography variant="body2" color="text.secondary" mb={2}>
            Search and select groups to assign this user to.
          </Typography>
          <Divider sx={{ mb: 2 }} />

          <Autocomplete
            multiple
            options={allGroups}
            value={selectedGroups}
            onChange={(_e, newValue) => {
              hasEdited.current = true;
              setSelectedGroups(newValue as ThunderGroup[]);
            }}
            getOptionLabel={(option) => (option as ThunderGroup).name}
            isOptionEqualToValue={(option, value) =>
              (option as ThunderGroup).id === (value as ThunderGroup).id
            }
            renderTags={() => null}
            renderInput={(params) => (
              <TextField
                {...params}
                placeholder="Search groups..."
                label="Groups"
              />
            )}
            noOptionsText="No groups found"
          />

          {selectedGroups.length > 0 && (
            <Stack direction="row" flexWrap="wrap" gap={1} mt={1.5}>
              {selectedGroups.map((group) => (
                <Chip
                  key={group.id}
                  label={group.name}
                  size="small"
                  onDelete={() => {
                    hasEdited.current = true;
                    setSelectedGroups((prev) => prev.filter((g) => g.id !== group.id));
                  }}
                />
              ))}
            </Stack>
          )}
        </Box>

        <Stack direction="row" spacing={1} justifyContent="flex-end">
          <Button variant="outlined" onClick={() => navigate(usersPath)} disabled={isSaving}>
            Cancel
          </Button>
          <Button variant="contained" onClick={handleSave} disabled={isSaving}>
            {isSaving ? "Saving..." : "Save Changes"}
          </Button>
        </Stack>
      </Stack>
    </PageLayout>
  );
};
