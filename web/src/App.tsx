import { Navigate, Route, Routes, useParams } from 'react-router-dom'
import { useAuthUser } from './data/auth'
import { SignInPage } from './ui/SignInPage'
import { UIDProvider } from './ui/UserContext'
import { AppShell } from './ui/shell/AppShell'
import { NotFound } from './ui/shell/NotFound'
import { FeedPage } from './ui/feed/FeedPage'
import { FollowUpsPage } from './ui/followups/FollowUpsPage'
import { LogPage } from './ui/log/LogPage'
import { PeopleListPage } from './ui/people/PeopleListPage'
import { PersonPage } from './ui/people/PersonPage'
import { NotesPage } from './ui/notes/NotesPage'
import { FolderPage } from './ui/folders/FolderPage'
import { FoldersPage } from './ui/folders/FoldersPage'
import { SettingsPage } from './ui/settings/SettingsPage'

/// `/projects/:id` kept its id when it became `/folders/:id`, so the old link
/// still opens the same thing rather than the list.
function LegacyProjectRoute() {
  const { folderID } = useParams()
  return <Navigate to={`/folders/${folderID}`} replace />
}

function App() {
  const { user, ready } = useAuthUser()

  if (!ready) return null
  if (!user) return <SignInPage />

  return (
    <UIDProvider uid={user.uid}>
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<FeedPage />} />
          <Route path="/people" element={<PeopleListPage />} />
          <Route path="/people/:personID" element={<PersonPage />} />
          <Route path="/notes" element={<NotesPage />} />
          <Route path="/notes/:noteID" element={<NotesPage />} />
          <Route path="/folders" element={<FoldersPage />} />
          <Route path="/folders/:folderID" element={<FolderPage />} />
          {/* Projects became Folders. The old paths still land rather than
              404ing, because a link may be sitting in somebody's history. */}
          <Route path="/projects" element={<Navigate to="/folders" replace />} />
          <Route path="/projects/:folderID" element={<LegacyProjectRoute />} />
          <Route path="/followups" element={<FollowUpsPage />} />
          <Route path="/log" element={<LogPage />} />
          {/* Capture lives inline on the feed now; the old page redirects. */}
          <Route path="/capture" element={<Navigate to="/?capture=1" replace />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </UIDProvider>
  )
}

export default App
